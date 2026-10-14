class CreateCorreiosLogOrdersJob2 < ActiveJob::Base
  queue_as :default
  include ApplicationHelper

  def perform(param, order, marker_id = nil)
    # return unless ScheduleUtils.within_schedule?

    Attempt.where(kinds: :create_correios_order_tiny2, status: :success).find_each do |attempt|
      next unless attempt.message.present?

      if attempt.message =~ /\/pedidos\/(\d+)/
        order_id = attempt.message[/\/pedidos\/(\d+)/, 1]

        attempt.update(order_correios_id: order_id)
      end
    end

    case param
    when 'all'
      create_correios_log_orders
    when 'one'
      create_one_log_order(order)
    end

    Attempt.find_by(id: marker_id)&.update(status: :success) if marker_id
  rescue StandardError => e
    Attempt.find_by(id: marker_id)&.update(status: :error, error: e.message) if marker_id
    raise
  end

  def create_correios_log_orders
    # Todas as páginas da fila (o Tiny devolve 100 pedidos por página).
    orders = Tiny::Orders.get_all_orders_response('preparando_envio', ENV.fetch('TOKEN_TINY2_PRODUCTION'), '14/06/2025')
    Array(orders&.dig(:pedidos)).each do |order|
      process_order(order)
    end
  end

  def process_order(order)
    return unless order.present?

    return if Attempt.find_by(
      tiny_order_id: order[:pedido][:id],
      status: :success,
      kinds: :create_correios_order_tiny2
    ).present?

    attempt = Attempt.where(
      tiny_order_id: order[:pedido][:id],
      kinds: :create_correios_order_tiny2
    ).last

    if attempt&.message.to_s =~ /ID do pedido: (\d+)/
      order_id = Regexp.last_match(1)
      attempt.update(order_correios_id: order_id, status: :success)
      return
    end

    create_one_log_order(order)
  end

  def create_one_log_order(order)
    review = Tiny2OrderReview.decision_for(order[:pedido][:id])
    return unless review&.approved?

    params = {
      invoice: '',
      numero_ecommerce: '',
      data_pedido: '',
      valor: '',
      nome: '',
      endereco: '',
      numero: '',
      complemento: '',
      bairro: '',
      cep: '',
      cidade: '',
      uf: '',
      fone: '',
      email: '',
      cpf_cnpj: '',
      pedido_id: '',
      forma_envio: '',
      cnpj_transportadora: '',
      itens: []
    }

    # Create Attempt
    attempt = Attempt.create!(kinds: :create_correios_order_tiny2,
                              tiny_order_id: order[:pedido][:id])

    # Obtain more info from a specific order
    begin
      selected_order = Tiny::Orders.obtain_order(ENV.fetch('TOKEN_TINY2_PRODUCTION'), order[:pedido][:id])
    rescue StandardError => e
      attempt.update(error: e, status: :error)
    end

    p 'Sleeping 3 seconds'
    sleep(3)
    p 'Waking Up, and get back to work!'

    # Obtain invoice number
    # begin
    #   invoice = Tiny::Invoices.obtain_invoice(selected_order[:pedido][:id_nota_fiscal])
    # rescue StandardError => e
    #   attempt.update(error: e, status: :error)
    # end

    # Verify order founded
    attempt.update(error: "Order - #{order[:pedido][:id]} não encontrada", status: :error) unless selected_order.present?

    # Verifying client data after continue
    attempt.update(error: 'Dados do Cliente não disponíveis', status: :error) unless selected_order.present? && selected_order[:pedido].present? && selected_order[:pedido][:cliente].present?

    # Find client data on selected order hash
    return attempt unless selected_order.present? && selected_order[:pedido].present? && selected_order[:pedido][:cliente].present?
    client_data = selected_order[:pedido][:cliente]

    # Some 'total_pedido' have a zero value, reasoned by discount
    # if selected_order[:pedido][:total_pedido] > selected_order[:pedido][:total_produtos]
    #   assert_value = selected_order[:pedido][:total_pedido]
    # else
    #   assert_value = selected_order[:pedido][:total_produtos]
    # end
    assert_value = '50.00'

    # assert ecommerce
    if selected_order[:pedido][:numero_ecommerce].present?
      ecommerce_number = selected_order[:pedido][:numero_ecommerce]
    else
      ecommerce_number = '0'
    end

    # assert email
    if client_data[:email].present?
      email = client_data[:email]
    else
      email = 'contato@chasebrasil.com'
    end

    # assert address
    if selected_order[:pedido][:endereco_entrega].present?
      endereco = selected_order[:pedido][:endereco_entrega][:endereco]
      numero = selected_order[:pedido][:endereco_entrega][:numero]
      complemento = selected_order[:pedido][:endereco_entrega][:complemento]
      bairro = selected_order[:pedido][:endereco_entrega][:bairro]
      cep = selected_order[:pedido][:endereco_entrega][:cep]
      cidade = selected_order[:pedido][:endereco_entrega][:cidade]
      fone = selected_order[:pedido][:endereco_entrega][:fone]
      uf = selected_order[:pedido][:endereco_entrega][:uf]
      cpf = selected_order[:pedido][:endereco_entrega][:cpf_cnpj]
    else
      endereco = client_data[:endereco]
      numero = client_data[:numero]
      complemento = client_data[:complemento]
      bairro = client_data[:bairro]
      cep = client_data[:cep]
      cidade = client_data[:cidade]
      fone = client_data[:fone]
      uf = client_data[:uf]
      cpf = client_data[:cpf_cnpj]
    end

    # Pedidos com correção salva no Honey usam esse endereço no lugar do da Tiny
    if (correction = AddressCorrection.for(order[:pedido][:id]))
      endereco = correction.endereco.presence || endereco
      numero = correction.numero.presence || numero
      complemento = correction.complemento.presence || complemento
      bairro = correction.bairro.presence || bairro
      cep = correction.cep.presence || cep
      cidade = correction.cidade.presence || cidade
      uf = correction.uf.presence || uf
    end

    # Transferência B2C (mão própria, identificada nas observações): vai pelo serviço 74926 (o mesmo da
    # transportadora) com o adicional de mão própria, sem forma de frete.
    hand_delivery = hand_delivery?(selected_order[:pedido])

    # assert sending way
    unless hand_delivery || selected_order.dig(:pedido, :forma_frete).present?
      attempt.update(error: 'Forma de Envio não localizada', status: :error)
      return attempt
    end

    transportadora_nome = selected_order[:pedido][:nome_transportador]
    via_transportadora = !hand_delivery && transportadora_nome.present? && !transportadora_nome.strip.downcase.include?('correios')

    if hand_delivery
      forma_envio_code = HAND_DELIVERY_SERVICE
    elsif via_transportadora
      forma_envio_code = '74926'

      begin
        invoice = Tiny::Invoices.obtain_invoice(selected_order[:pedido][:id_nota_fiscal])
        cnpj_transportadora = invoice[:transportador][:cpf_cnpj].to_s.gsub(/\D/, '')
      rescue StandardError => e
        attempt.update(error: e, status: :error)
        return attempt
      end

      unless cnpj_transportadora.present?
        attempt.update(error: 'CNPJ da transportadora não localizado', status: :error)
        return attempt
      end
    else
      forma_envio_code = case selected_order[:pedido][:forma_frete]
                         when 'SEDEX CORREIOS LOG+'
                           '39888'
                         when 'PAC CORREIOS LOG+'
                           '39870'
                         when 'SEDEX HOJE LOG+'
                           '06602'
                         else
                           attempt.update(error: 'Forma de Envio desconhecida', status: :error)
                           return attempt
                         end
    end

    # Setting founded valures
    begin
      params[:invoice]          = order[:pedido][:id]
      params[:numero_ecommerce] = ecommerce_number
      params[:data_pedido]      = selected_order[:pedido][:data_pedido]
      params[:valor]            = assert_value
      params[:nome]             = client_data[:nome]
      params[:endereco]         = endereco
      params[:numero]           = numero
      params[:complemento]      = complemento
      params[:bairro]           = bairro
      params[:cep]              = cep.gsub(/\D/, '')
      params[:cidade]           = cidade
      params[:uf]               = uf
      params[:fone]             = fone.gsub(/\D/, '')
      params[:email]            = email
      params[:cpf_cnpj]         = cpf.gsub(/\D/, '')
      params[:pedido_id]        = selected_order[:pedido][:id]
      params[:forma_envio]      = forma_envio_code
      params[:cnpj_transportadora] = cnpj_transportadora if via_transportadora
      params[:mao_propria]      = true if hand_delivery

      # Form items array
      order_items = selected_order[:pedido][:itens]

      order_items.each do |oi|
        params[:itens] << { codigo: oi[:item][:codigo].upcase, quantidade: oi[:item][:quantidade].sub(/\.?0*\z/, '') }
      end

      attempt.update(id_nota_fiscal: selected_order[:pedido][:id_nota_fiscal].to_i, is_transportadora: via_transportadora, params:)

      verify_params(attempt, params)
    rescue StandardError => e
      attempt.update(error: e, status: :error)
    end

    # Create Order in Correios Log +
    # Transferência B2B -> B2C: só o destinatário enviado aos Correios vai identificado como transferência.
    recipient_name = B2bTinyService::B2C_TRANSFER_RECIPIENT_NAME if b2c_transfer?(selected_order[:pedido])
    Correios::Orders.create_orders(params, attempt, recipient_name:) unless attempt.error.present?

    attempt
  end

  # Mão própria é serviço adicional (Correios::Orders::MAO_PROPRIA): o serviço de postagem é o 74926,
  # o mesmo usado para transportadora.
  HAND_DELIVERY_SERVICE = '74926'.freeze

  def hand_delivery?(pedido)
    tags = [B2bTinyService::HAND_DELIVERY_TAG, B2bTinyService::B2C_TRANSFER_TAG].map(&:downcase)
    notes = [pedido[:obs], pedido[:obs_interna]].compact.join(' ').downcase
    tags.any? { |tag| notes.include?(tag) }
  end

  # Transferência B2B -> B2C: marcada nas observações com B2C_TRANSFER_TAG.
  def b2c_transfer?(pedido)
    notes = [pedido[:obs], pedido[:obs_interna]].compact.join(' ').downcase
    notes.include?(B2bTinyService::B2C_TRANSFER_TAG.downcase)
  end

  def verify_params(attempt, params)
    required_params = [:data_pedido, :valor, :nome, :endereco, :bairro, :cep, :cidade, :numero, :uf, :email, :cpf_cnpj, :invoice, :forma_envio]

    missing_params = required_params.select { |param| params[param] == '' }

    return unless missing_params.any?
    error_message = "#{missing_params.join(', ')} não presente"
    attempt.update(error: error_message, status: :error)
  end
end
