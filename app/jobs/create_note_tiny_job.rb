class CreateNoteTinyJob < ActiveJob::Base
  queue_as :default

  def perform(planner_order_id)
    planner_order = PlannerOrder.find(planner_order_id)

    Rails.logger.info "[CreateNoteTinyJob] Iniciando criação de nota para PlannerOrder ##{planner_order_id}"

    begin
      items_data = fetch_products_from_local(planner_order)

      nota = mount_note(planner_order, items_data)

      response = send_to_tiny2(nota)

      process_response(planner_order, response)

      Rails.logger.info "[CreateNoteTinyJob] Nota criada com sucesso"

    rescue => e
      planner_order.update(
        status: :error,
        error_message: e.message
      )

      Rails.logger.error "[CreateNoteTinyJob] Erro: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
    end
  end

  private

  ############################################
  # BUSCA PRODUTOS LOCALMENTE
  ############################################

  def fetch_products_from_local(planner_order)
    items_data = []

    skus = planner_order.planner_order_items.pluck(:sku)

    products_by_sku = Product.where(sku: skus).index_by(&:sku)

    planner_order.planner_order_items.each do |item|
      product = products_by_sku[item.sku]

      unless product
        Rails.logger.warn "[CreateNoteTinyJob] Produto não encontrado SKU=#{item.sku}"

        items_data << build_basic_item_data(item)
        next
      end

      cost = resolve_cost(product)

      Rails.logger.info "[CreateNoteTinyJob] SKU=#{item.sku} cost=#{cost}"

      items_data << {
        codigo: item.sku,
        descricao: item.name,
        unidade: 'UN',
        quantidade: item.quantity.to_s,
        valor_unitario: format('%.2f', cost),
        tipo: 'P',
        cfop: '5152'
      }
    end

    items_data
  end

  ############################################
  # RESOLVE COST
  ############################################

  def resolve_cost(product)
    local_cost = product.cost.to_f

    return local_cost if local_cost > 0

    Rails.logger.info "[CreateNoteTinyJob] Cost vazio, buscando no Tiny SKU=#{product.sku}"

    tiny_cost = fetch_cost_from_tiny(product)

    if tiny_cost > 0
      product.update!(cost: tiny_cost)

      Rails.logger.info "[CreateNoteTinyJob] Cost atualizado SKU=#{product.sku} cost=#{tiny_cost}"

      return tiny_cost
    end

    0.0
  end

  ############################################
  # BUSCA COST NO TINY
  ############################################

  def fetch_cost_from_tiny(product)
    return 0.0 unless product&.tiny_2_id.present?

    url = ENV.fetch(
      'OBTER_PRODUTO',
      'https://api.tiny.com.br/api2/produto.obter.php'
    )

    response = HTTParty.get(
      url,
      query: {
        token: ENV.fetch('TOKEN_TINY2_PRODUCTION'),
        formato: 'json',
        id: product.tiny_2_id
      }
    )

    parsed = JSON.parse(response.body)

    status = parsed.dig('retorno', 'status')

    unless status == 'OK'
      Rails.logger.error "[CreateNoteTinyJob] Tiny status inválido SKU=#{product.sku}"
      return 0.0
    end

    cost = parsed
      .dig('retorno', 'produto', 'preco_custo')
      .to_f

    Rails.logger.info "[CreateNoteTinyJob] Tiny cost SKU=#{product.sku} cost=#{cost}"

    cost

  rescue => e
    Rails.logger.error "[CreateNoteTinyJob] Erro Tiny SKU=#{product.sku} erro=#{e.message}"
    0.0
  end

  def build_basic_item_data(item)
    product = Product.find_by(sku: item.sku)

    cost = product ? resolve_cost(product) : 0.0

    {
      codigo: item.sku,
      descricao: item.name,
      unidade: 'UN',
      quantidade: item.quantity.to_s,
      valor_unitario: format('%.2f', cost),
      tipo: 'P',
      cfop: '5152'
    }
  end

  def mount_note(planner_order, items_data)
    total_valor_produtos =
      items_data.sum do |item|
        item[:valor_unitario].to_f * item[:quantidade].to_f
      end

    valor_icms = (total_valor_produtos * 0.18).round(2)

    valor_nota = (total_valor_produtos + valor_icms).round(2)

    obs_parts = []

    obs_parts << "pedido #{planner_order.order_number}" if planner_order.order_number.present?
    obs_parts << planner_order.tags if planner_order.tags.present?
    obs_parts << "Depósito: Padrão"
    obs_parts << "Ref: #{planner_order.reference}"

    {
      nota_fiscal: {
        tipo: 'S',

        natureza_operacao: 'CFOP 5152 - Transferência de mercadoria adquirida ou recebida de terceiros',

        data_emissao: Time.current.strftime('%d/%m/%Y'),

        data_entrada_saida: Time.current.strftime('%d/%m/%Y'),

        hora_entrada_saida: Time.current.strftime('%H:%M'),

        cliente: {
          nome: 'Chase Brasil Comercio de Artigos Esportivos Ltda',
          tipo_pessoa: 'J',
          cpf_cnpj: '25.405.327/0001-74',
          ie: '29090240004',
          endereco: 'Rua Juvenal de Melo Senra',
          numero: '355',
          complemento: '',
          bairro: 'Belvedere',
          cep: '30.320-660',
          cidade: 'Belo Horizonte',
          uf: 'MG',
          fone: '',
          email: 'chase3@chase.com',
          atualizar_cliente: 'N'
        },

        itens: items_data.map { |item| { item: item } },

        valor_produtos: format('%.2f', total_valor_produtos),

        valor_icms: format('%.2f', valor_icms),

        base_icms: format('%.2f', total_valor_produtos),

        valor_nota: format('%.2f', valor_nota),

        valor_faturado: format('%.2f', valor_nota),

        frete_por_conta: 'R',

        obs: obs_parts.join(' | ')
      }
    }
  end

  def send_to_tiny2(nota)
    url = ENV.fetch(
      'INCLUIR_NOTA',
      'https://api.tiny.com.br/api2/nota.fiscal.incluir.php'
    )

    HTTParty.post(
      url,
      body: {
        token: ENV.fetch('TOKEN_TINY2_PRODUCTION'),
        formato: 'json',
        nota: nota.to_json
      }
    )
  end

  def process_response(planner_order, response)
    retorno = JSON.parse(response.body)

    status = retorno.dig('retorno', 'status')

    status_processamento = retorno.dig('retorno', 'status_processamento')

    registro = retorno.dig('retorno', 'registros', 'registro')

    numero = registro&.dig('numero')

    erro = registro&.dig('erro')

    if (status_processamento == '3' && status == 'OK') || erro&.include?('duplicidade')

      planner_order.update!(
        status: :transmitted,
        transmitted_at: Time.current,
        tiny_note_number: numero,
        tiny_response: retorno.to_json
      )

    else
      planner_order.update!(
        status: :error,
        error_message: erro,
        tiny_response: retorno.to_json
      )

      raise erro
    end
  end
end
