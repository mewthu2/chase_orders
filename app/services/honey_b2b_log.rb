# Log02 dos pedidos feitos no Honey (atacado, abastecimento e transferência B2C), sem o Tiny:
#
#   aprovado ──criação──▶ preparando_envio (correios_order_id) ──NF-e + XML──▶ faturado (xml_sent_at)
#            ──rastreio──▶ enviado (tracking_code)
#
# Cada passo grava uma tentativa (Attempt create_correios_order_honey / send_xml_honey / get_tracking_honey,
# com b2b_order_id) e roda no fim do job do Log02 da mesma etapa, então segue o agendador e os botões de
# hoje. Na etapa do XML a NF-e é emitida no Honey (empresa e natureza da Configuração do atacado),
# autorizada na SEFAZ, e o XML autorizado vai para o Correios.
class HoneyB2bLog
  SEDEX_SERVICE = '39888'.freeze
  CARRIER_SERVICE = '74926'.freeze
  DECLARED_VALUE = '50.00'.freeze # o mesmo valor declarado que o fluxo do Tiny usa
  FALLBACK_EMAIL = 'contato@chasebrasil.com'.freeze
  # Destinatário fixo da transferência B2C, com o código IBGE de Belo Horizonte para a NF-e.
  B2C_RECIPIENT_IBGE = '3106200'.freeze

  class << self
    def create_pending!
      each_safely(B2bOrder.honey_flow.aprovado.where(correios_order_id: nil, log_ignored: false)) { |o| create_in_correios(o) }
    end

    def send_pending_xml!
      each_safely(B2bOrder.honey_flow.where.not(correios_order_id: nil).where(xml_sent_at: nil).where.not(status: :cancelado)) { |o| send_xml(o) }
    end

    def track_pending!
      each_safely(B2bOrder.honey_flow.where.not(xml_sent_at: nil).where(tracking_code: [nil, '']).where.not(status: :cancelado)) { |o| fetch_tracking(o) }
    end

    # Reservas do Log02 dos pedidos do Honey ainda fora do Correios (chave "H<id>" na tabela de reservas).
    def sync_reservations!
      orders = B2bOrder.reserving_stock.includes(:b2b_order_items, :client, :transfer_location).to_a
      keys = orders.map(&:reservation_key)
      StockReservation.b2b.where('tiny_order_id LIKE ?', "#{B2bOrder::RESERVATION_PREFIX}%").where.not(tiny_order_id: keys).delete_all

      now = Time.current
      orders.each do |order|
        StockReservation.b2b.where(tiny_order_id: order.reservation_key).delete_all
        quantities = order.b2b_order_items.each_with_object(Hash.new(0)) { |i, acc| acc[i.sku.to_s.strip.upcase] += i.quantity.to_i if i.sku.present? }
        next if quantities.empty?

        StockReservation.insert_all(quantities.map do |sku, quantity|
          { account: StockReservation.accounts[:b2b], tiny_order_id: order.reservation_key, tiny_order_number: order.reservation_key,
            customer_name: destination_name(order).to_s.first(255), order_date: order.created_at&.to_date, sku:, quantity:,
            created_at: now, updated_at: now }
        end)
      end
    end

    def destination_name(order)
      if order.sale? then order.client&.display_name
      elsif order.stock_transfer? then order.transfer_location&.name
      else B2bTinyService::B2C_TRANSFER_RECIPIENT[:nome]
      end
    end

    private

    # Um pedido com problema não pode parar os outros, nem o fluxo do Tiny que roda no mesmo job.
    def each_safely(scope)
      scope.find_each do |order|
        yield order
      rescue StandardError => e
        Rails.logger.error "HoneyB2bLog pedido #{order.id}: #{e.class} #{e.message}"
      end
    end
  end

  def self.create_in_correios(order) = new(order).create_in_correios
  def self.send_xml(order) = new(order).send_xml
  def self.fetch_tracking(order) = new(order).fetch_tracking

  def initialize(order)
    @order = order
  end

  # ---- 1. criação no Correios ----
  def create_in_correios
    attempt = Attempt.create!(kinds: :create_correios_order_honey, b2b_order_id: @order.id)
    params, recipient_name, error = correios_params
    return attempt.tap { |a| a.update(status: :error, error: error) } if error

    attempt.update(params: params, is_transportadora: params[:cnpj_transportadora].present?)
    Correios::Orders.create_orders(params, attempt, recipient_name:)
    attempt.reload
    if attempt.success? && attempt.order_correios_id.to_i.positive?
      @order.update_columns(correios_order_id: attempt.order_correios_id, status: B2bOrder.statuses[:preparando_envio], updated_at: Time.current)
      self.class.sync_reservations!
    end
    attempt
  end

  # ---- 2. NF-e no Honey + XML para o Correios ----
  def send_xml
    attempt = Attempt.create!(kinds: :send_xml_honey, b2b_order_id: @order.id, order_correios_id: @order.correios_order_id)
    note = authorized_note
    unless note&.autorizada?
      attempt.update(status: :error, error: "NF-e não autorizada: #{note_problem(note)}".first(255))
      return attempt
    end

    attempt.update!(xml_nota: note.xml.download.delete("\n"), id_nota_fiscal: note.number, is_transportadora: carrier_service?)
    Correios::Invoices.send_xml_to_correios(attempt)
    attempt.reload
    if xml_accepted?(attempt)
      @order.update_columns(xml_sent_at: Time.current, status: B2bOrder.statuses[:faturado], updated_at: Time.current)
      attempt.update(status: :success) unless attempt.success?
    end
    attempt
  end

  # ---- 3. rastreio ----
  def fetch_tracking
    attempt = Attempt.create!(kinds: :get_tracking_honey, b2b_order_id: @order.id, order_correios_id: @order.correios_order_id)
    tracking = Correios::Orders.get_tracking(@order.correios_order_id, from_tiny2: true)
    code = tracking.is_a?(Hash) || tracking.respond_to?(:dig) ? tracking.dig('rastreio', 0, 'codigoObjeto') : nil
    if code.present?
      attempt.update(status: :success, tracking: code)
      @order.update_columns(tracking_code: code, status: B2bOrder.statuses[:enviado], updated_at: Time.current)
    else
      attempt.update(status: :error, error: 'Correios ainda não disponibilizou o código de rastreio')
    end
    attempt
  rescue StandardError => e
    attempt&.update(status: :error, error: e.message.to_s.first(255), message: 'Erro na solicitação de rastreio aos Correios')
    attempt
  end

  private

  def setting = (@setting ||= B2bSetting.current)

  # 200: o Correios recebeu o XML (o rastreio vem depois). 400 "já faturado": ele já tinha a nota.
  def xml_accepted?(attempt)
    attempt.success? || attempt.status_code.to_s == '200' ||
      (attempt.status_code.to_s == '400' && attempt.message.to_s.match?(/faturad/i))
  end

  # Nota de PRODUÇÃO do pedido (a de homologação é teste e não vai ao Correios): usa a que já existe (por
  # exemplo, emitida na aba Nota fiscal do pedido) ou gera; e autoriza na SEFAZ se ainda não estiver.
  def authorized_note
    note = FiscalNote.active_statuses.where(b2b_order_id: @order.id, environment: :producao).order(:id).last
    note ||= FiscalNote.erro.where(b2b_order_id: @order.id, environment: :producao).order(:id).last&.tap { |n| Nfe::Transmitter.call(n, consult: true) }&.reload
    note = nil unless note.nil? || FiscalNote::ACTIVE_STATUSES.include?(note.status)
    note ||= generate_note
    return note if note.nil? || note.autorizada?

    Nfe::Transmitter.call(note) if note.transmittable?
    note.reload
  rescue Nfe::Generator::Error, Nfe::Transmitter::Error => e
    @note_error = e.message
    nil
  end

  def generate_note
    company = setting.issuer
    nature = setting.nature_for(@order)
    raise Nfe::Generator::Error, 'Escolha a empresa emissora em Configuração do atacado.' unless company
    raise Nfe::Generator::Error, "Escolha a natureza de #{@order.sale? ? 'venda' : 'transferência'} em Configuração do atacado." unless nature
    unless company.producao?
      raise Nfe::Generator::Error, "#{company.selection_label} está em homologação: ligue a produção para o Log02 emitir a nota e mandar o XML ao Correios."
    end

    CompanyOperationNature.find_or_create_by!(company:, operation_nature: nature)
    Nfe::Generator.call(order: @order, company:, nature:, environment: 'producao')
  rescue ActiveRecord::RecordInvalid => e
    raise Nfe::Generator::Error, e.record.errors.full_messages.to_sentence
  end

  def note_problem(note)
    return @note_error if @note_error
    return 'nota não gerada' unless note

    note.error_message.presence || note.sefaz_message.presence || "situação #{note.status}"
  end

  def carrier_service?
    correios_service.first == CARRIER_SERVICE
  end

  # [código do serviço, CNPJ da transportadora, mão própria?]
  def correios_service
    @correios_service ||= if @order.b2c_transfer?
                            [CARRIER_SERVICE, digits(B2bTinyService::B2C_TRANSFER_RECIPIENT[:cpf_cnpj]), false]
                          elsif @order.carrier.present? && (@order.stock_transfer? || @order.freight_service.blank?)
                            [CARRIER_SERVICE, digits(@order.carrier.registration), false]
                          elsif @order.sale? && @order.freight_service.blank?
                            [nil, nil, false]
                          else
                            [SEDEX_SERVICE, nil, @order.stock_transfer?]
                          end
  end

  def correios_params
    service, carrier_cnpj, hand_delivery = correios_service
    return [nil, nil, 'Escolha a forma de envio do pedido (SEDEX ou transportadora).'] unless service

    address = destination_address
    return [nil, nil, 'Pedido sem destinatário (cliente ou loja de destino).'] unless address

    items = @order.b2b_order_items.map { |i| { codigo: i.sku.to_s.upcase, quantidade: i.quantity.to_s } }
    params = {
      invoice: @order.correios_number, numero_ecommerce: @order.id.to_s, data_pedido: Time.current.strftime('%d/%m/%Y'),
      valor: DECLARED_VALUE, pedido_id: @order.correios_number, forma_envio: service, itens: items
    }.merge(address)
    params[:cnpj_transportadora] = carrier_cnpj if carrier_cnpj
    params[:mao_propria] = true if hand_delivery

    missing = %i[nome endereco bairro cep cidade uf cpf_cnpj].select { |k| params[k].blank? }
    return [nil, nil, "Faltam dados do destinatário: #{missing.join(', ')}"] if missing.any?

    [params, recipient_name(hand_delivery), nil]
  end

  def destination_address
    if @order.sale?
      client = @order.client or return nil
      street = @order.different_shipping_address? ? shipping_address : address_of(client)
      { nome: client.display_name, cpf_cnpj: digits(client.registration), email: client.email.presence || FALLBACK_EMAIL,
        fone: digits(client.phone) }.merge(street)
    elsif @order.stock_transfer?
      loc = @order.transfer_location or return nil
      { nome: loc.name, cpf_cnpj: digits(loc.registration), email: FALLBACK_EMAIL, fone: '' }.merge(address_of(loc))
    else
      r = B2bTinyService::B2C_TRANSFER_RECIPIENT
      { nome: r[:nome], cpf_cnpj: digits(r[:cpf_cnpj]), email: FALLBACK_EMAIL, fone: '', endereco: r[:endereco], numero: r[:numero],
        complemento: r[:complemento], bairro: r[:bairro], cep: digits(r[:cep]), cidade: r[:cidade], uf: r[:uf] }
    end
  end

  def address_of(source)
    { endereco: source.street, numero: source.number, complemento: source.try(:complement).to_s, bairro: source.neighbourhood,
      cep: digits(source.zip), cidade: source.city, uf: source.state }
  end

  def shipping_address
    { endereco: @order.shipping_street, numero: @order.shipping_number, complemento: @order.shipping_complement.to_s,
      bairro: @order.shipping_neighbourhood, cep: digits(@order.shipping_zip), cidade: @order.shipping_city, uf: @order.shipping_state }
  end

  # Mão própria: só quem está em "Responsável pelo recebimento" recebe (até 60 caracteres, como no fluxo do Tiny).
  # Transferência B2C: o destinatário vai identificado como transferência.
  def recipient_name(hand_delivery)
    return B2bTinyService::B2C_TRANSFER_RECIPIENT_NAME if @order.b2c_transfer?
    return nil unless hand_delivery

    names = @order.receiver_name.to_s.split(',').map(&:strip).reject(&:blank?)
    return nil if names.empty?

    fitting = names.each_with_object([]) { |name, acc| break acc if [*acc, name].join(', ').length > 60; acc << name }
    fitting.any? ? fitting.join(', ') : names.first.first(60)
  end

  def digits(value) = value.to_s.gsub(/\D/, '')
end
