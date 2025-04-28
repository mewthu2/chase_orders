class CreateShopifyOrdersFromTinyJob < ActiveJob::Base
  def perform(kind, tiny_order_id)
    puts "Iniciando importação de pedido #{tiny_order_id} do Tiny (#{kind}) para Shopify..."

    begin
      case kind
      when 'bh_shopping'
        token = ENV.fetch('TOKEN_TINY_PRODUCTION_BH_SHOPPING')
        @stock_client_id = 8158813257802
      when 'lagoa_seca'
        token = ENV.fetch('TOKEN_TINY_PRODUCTION')
        @stock_client_id = 8428671795274
      when 'rj'
        token = ENV.fetch('TOKEN_TINY_PRODUCTION_RJ')
        @stock_client_id = 8425771532362
      end

      response = Tiny::Orders.obtain_order(token, tiny_order_id)
      create_fulfilled_order(kind, response, tiny_order_id)

    rescue StandardError => e
      # Cria attempt de falha apenas se não existir nenhum attempt para este pedido
      unless Attempt.exists?(tiny_order_id:)
        Attempt.create(
          tiny_order_id:,
          status: Attempt.statuses[:failed],
          error: e.message,
          exception: e.class.to_s,
          tracking: "#{kind}|error:#{e.class}",
          classification: 'exception',
          message: e.backtrace.join("\n")
        )
      end
      puts "Erro ao processar pedido #{tiny_order_id}: #{e.message}"
      raise e
    ensure
      Time.now
    end
  end

  def create_fulfilled_order(kind, response, tiny_order_id)
    case kind
    when 'bh_shopping'
      location_id = 72286699594
      access_token = ENV.fetch('BH_SHOPPING_TOKEN_APP')
    when 'rj'
      location_id = 72287027274
      access_token = ENV.fetch('BARRA_SHOPPING_TOKEN_APP')
    when 'lagoa_seca'
      location_id = 72286994506
      access_token = ENV.fetch('LAGOA_SECA_TOKEN_APP')
    end

    session = ShopifyAPI::Auth::Session.new(
      shop: 'chasebrasil.myshopify.com',
      access_token:
    )

    pedido = response['pedido']
    cliente = pedido['cliente']

    # Preparar dados do cliente
    nome_completo = cliente['nome'] || 'Cliente Shopify'
    nomes = nome_completo.strip.split
    @first_name = nomes.first
    @last_name = nomes[1..].join(' ') if nomes.size > 1

    # Gerar telefone único
    customer_phone = cliente['fone'].present? ? generate_unique_phone(cliente['fone'], session) : ''

    # Construir endereço
    endereco = build_address_graphql(cliente, customer_phone)

    # Construir line items melhorados com variant_id
    line_items = pedido['itens'].map do |item|
      sku = item.dig('item', 'codigo') || ''
      variant_id = find_variant_id_by_sku(session, sku)

      line_item = {
        'quantity' => item.dig('item', 'quantidade').to_i,
        'originalUnitPrice' => item.dig('item', 'valor_unitario').to_f,
        'taxable' => false,
        'title' => item.dig('item', 'descricao') || 'Produto sem nome'
      }

      line_item['variantId'] = "gid://shopify/ProductVariant/#{variant_id}" if variant_id
      line_item
    end

    # Criar draft order
    draft_order = create_draft_order(
      session:,
      line_items:,
      cliente:,
      customer_phone:,
      endereco:,
      pedido:,
      source_name: kind
    )
    return unless draft_order

    complete_draft_order_rest(
      session:,
      draft_order_id: draft_order['id'][/\d+/],
      location_id:,
      tiny_order_id:,
      kind:,
      pedido:
    )
  end

  def create_draft_order(session:, line_items:, cliente:, customer_phone:, endereco:, pedido:, source_name: nil)
    mutation = <<~GRAPHQL
      mutation DraftOrderCreate($input: DraftOrderInput!) {
        draftOrderCreate(input: $input) {
          draftOrder {
            id
            name
            appliedDiscount {
              title
              value
              valueType
            }
            localizedFields(first: 1) {
              edges {
                node {
                  key
                  value
                }
              }
            }
          }
          userErrors {
            field
            message
          }
        }
      }
    GRAPHQL

    # Formatar CPF/CNPJ
    cpf_cnpj = cliente['cpf_cnpj'] || ''
    formatted_cpf = if cpf_cnpj.gsub(/[^0-9]/, '').size == 11
                      cpf_cnpj.gsub(/(\d{3})(\d{3})(\d{3})(\d{2})/, '\1.\2.\3-\4')
                    else
                      cpf_cnpj
                    end

    # Construir localized fields para CPF
    localized_fields = []
    if formatted_cpf.present?
      localized_fields << {
        'key' => 'TAX_CREDENTIAL_BR',
        'value' => formatted_cpf
      }
    end

    # Montar o input base
    input = {
      'lineItems' => line_items,
      'email' => cliente['email'].presence || '',
      'phone' => format_phone_for_shopify(customer_phone),
      'shippingAddress' => endereco,
      'billingAddress' => endereco,
      'note' => cliente['obs'] || '',
      'tags' => pedido['nome_vendedor'],
      'localizedFields' => localized_fields,
      'sourceName' => source_name
    }

    # Adicionar desconto se houver
    if pedido['valor_desconto'].to_f.positive?
      input['appliedDiscount'] = {
        'value' => pedido['valor_desconto'].to_f,
        'valueType' => 'FIXED_AMOUNT',
        'title' => 'Desconto comercial'
      }
    end

    # Enviar a mutation
    client = ShopifyAPI::Clients::Graphql::Admin.new(session:)
    response = client.query(query: mutation, variables: { input: })

    if response.body['errors'] || response.body.dig('data', 'draftOrderCreate', 'userErrors').any?
      puts "Erro ao criar draft order: #{response.body['errors'] || response.body.dig('data', 'draftOrderCreate', 'userErrors')}"
      nil
    else
      draft_order = response.body.dig('data', 'draftOrderCreate', 'draftOrder')
      puts "Draft order criado: #{draft_order['name']}"
      draft_order
    end
  end

  def complete_draft_order_rest(session:, draft_order_id:, location_id:, tiny_order_id:, kind:, pedido:)
    client = ShopifyAPI::Clients::Rest::Admin.new(session:)

    begin
      attempt = Attempt.create(
        kinds: :transfer_tiny_to_shopify_order,
        tiny_order_id:,
        status: Attempt.statuses[:processing],
        tracking: "kind:#{kind}|draft_order_id:#{draft_order_id}"
      )

      response = client.get(path: "draft_orders/#{draft_order_id}.json")
      draft_order = response.body['draft_order']

      unless draft_order
        attempt.update(
          status: Attempt.statuses[:failed],
          error: 'Draft order not found',
          tracking: "kind:#{kind}|failed:draft_order_not_found"
        )
        return puts('Draft order not found')
      end

      # Prepara dados do pedido
      order_data = {
        order: {
          email: draft_order['email'],
          send_receipt: false,
          send_fulfillment_receipt: false,
          line_items: draft_order['line_items'],
          customer: {
            id: draft_order['customer'].present? ? draft_order['customer']['id'] : @stock_client_id,
            email_marketing_consent: {
              state: draft_order.dig('customer', 'email_marketing_consent', 'state') || 'not_subscribed',
              opt_in_level: draft_order.dig('customer', 'email_marketing_consent', 'opt_in_level') || 'single_opt_in',
              consent_updated_at: draft_order.dig('customer', 'email_marketing_consent', 'consent_updated_at') || Time.now.iso8601
            },
            sms_marketing_consent: {
              state: draft_order.dig('customer', 'sms_marketing_consent', 'state') || 'not_subscribed',
              opt_in_level: draft_order.dig('customer', 'sms_marketing_consent', 'opt_in_level') || 'single_opt_in',
              consent_updated_at: draft_order.dig('customer', 'sms_marketing_consent', 'consent_updated_at') || Time.now.iso8601,
              consent_collected_from: draft_order.dig('customer', 'sms_marketing_consent', 'consent_collected_from') || 'OTHER'
            }
          },
          shipping_address: draft_order['shipping_address'],
          billing_address: draft_order['billing_address'],
          note: draft_order['note'],
          tags: draft_order['tags'].present? ? draft_order['tags'] : 'Sem vendedor',
          source_name: kind,
          created_at: Time.strptime("#{pedido['data_pedido']} #{Time.now.strftime('%H:%M:%S %z')}", '%d/%m/%Y %H:%M:%S %z').iso8601,
          financial_status: 'paid',
          transactions: [
            {
              kind: 'sale',
              status: 'success',
              amount: draft_order['total_price']
            }
          ],
          total_discounts: draft_order['applied_discount'] ? draft_order['applied_discount']['amount'] : '0.0',
          subtotal_price: if draft_order['applied_discount']
                            draft_order['subtotal_price'].to_f - draft_order['applied_discount']['amount'].to_f
                          else
                            draft_order['subtotal_price']
                          end
        }
      }
      # Cria o pedido
      order_response = client.post(path: 'orders.json', body: order_data)
      order = order_response.body['order']
      puts "Order created successfully: #{order['id']}"

      if location_id
        begin
          fulfillment_orders_response = client.get(path: "orders/#{order['id']}/fulfillment_orders.json")
          fulfillment_orders = fulfillment_orders_response.body['fulfillment_orders']

          fulfillment_orders.each do |fo|
            if fo['assigned_location_id'] != location_id && fo['supported_actions'].include?('move')
              begin
                client.post(
                  path: "fulfillment_orders/#{fo['id']}/move.json",
                  body: {
                    fulfillment_order: {
                      new_location_id: location_id
                    }
                  }
                )
                puts "Fulfillment order #{fo['id']} movido para location_id #{location_id}"
              rescue ShopifyAPI::Errors::HttpResponseError => e
                puts "Erro ao mover fulfillment_order #{fo['id']}: #{e.message}"
              end
            end

            begin
              client.post(
                path: 'fulfillments.json',
                body: {
                  fulfillment: {
                    message: 'Pedido entregue em mãos.',
                    notify_customer: false,
                    tracking_info: {
                      number: nil,
                      url: nil
                    },
                    line_items_by_fulfillment_order: [
                      {
                        fulfillment_order_id: fo['id']
                      }
                    ],
                    location_id:
                  }
                }
              )
              puts "Fulfillment criado para fulfillment_order_id #{fo['id']} com location_id #{location_id}"
            rescue ShopifyAPI::Errors::HttpResponseError => e
              puts "Erro ao criar fulfillment para fulfillment_order_id #{fo['id']}: #{e.message}"
            end
          end
        rescue ShopifyAPI::Errors::HttpResponseError => e
          puts "Erro ao buscar fulfillment_orders: #{e.message}"
        end
      end

      # Atualiza attempt com sucesso
      attempt.update(
        status: Attempt.statuses[:success],
        requisition: 'Pedido Shopify criado com sucesso',
        params: {
          shopify_order_id: order['id'],
          draft_order_id:,
          location_id:
        }.to_json,
        tracking: "kind:#{kind}|shopify_order_id:#{order['id']}"
      )

      {
        'id' => order['id'],
        'draft_order_id' => draft_order_id,
        'location_id' => location_id
      }
    rescue ShopifyAPI::Errors::HttpResponseError => e
      # Atualiza attempt com falha
      if attempt
        attempt.update(
          status: Attempt.statuses[:failed],
          error: e.message,
          exception: e.class.to_s,
          classification: 'shopify_error',
          message: e.response.body.to_s
        )
      else
        Attempt.create(
          tiny_order_id:,
          status: Attempt.statuses[:failed],
          error: e.message,
          exception: e.class.to_s,
          tracking: "kind:#{kind}|failed:#{e.class}",
          classification: 'shopify_error',
          message: e.response.body.to_s
        )
      end
      puts "Error: #{e.message}"
      nil
    end
  end

  def phone_unique?(phone, session)
    return false unless phone.present?

    customers = ShopifyAPI::Customer.all(
      session:,
      phone:,
      limit: 1
    )

    customers.empty?
  end

  def build_address_graphql(cliente, phone = nil)
    phone ||= format_phone_number(cliente['fone'])

    endereco = cliente['endereco'].presence || 'Sem endereço'
    numero = cliente['numero'].presence || '101'

    {
      'address1' => [endereco, numero].join(', '),
      'address2' => cliente['complemento'] || '',
      'city' => cliente['cidade'] || 'Cidade não informada',
      'province' => cliente['uf'] || 'SP',
      'country' => 'BR',
      'zip' => cliente['cep']&.gsub(/\D/, '') || '00000000',
      'firstName' => cliente['nome'].split.first,
      'lastName' => cliente['nome'].split[1..]&.join(' ') || '',
      'phone' => format_phone_for_shopify(phone),
      'company' => cliente['nome_fantasia'] || ''
    }
  end

  def generate_unique_phone(base_phone, session)
    return base_phone if phone_unique?(base_phone, session)

    3.times do |i|
      unique_phone = if base_phone.end_with?('9')
                        base_phone.gsub(/(\d{2})$/, (i + 1).to_s.rjust(2, '0'))
                      else
                        "#{base_phone}#{i + 1}"
                      end

      return unique_phone if phone_unique?(unique_phone, session)
    end

    "+55119#{SecureRandom.rand(100000000..999999999)}"
  end

  def format_phone_for_shopify(phone)
    return nil if phone.nil? || phone.empty?

    cleaned_phone = phone.gsub(/\D/, '')

    if cleaned_phone.start_with?('55')
      cleaned_phone
    elsif cleaned_phone.start_with?('0')
      cleaned_phone = "55#{cleaned_phone[1..]}"
    else
      cleaned_phone = "55#{cleaned_phone}"
    end

    cleaned_phone = cleaned_phone[0, 13] if cleaned_phone.length > 13

    "+#{cleaned_phone}"
  end

  def find_variant_id_by_sku(session, sku)
    return nil if sku.empty?
  
    query = <<~GRAPHQL
      query {
        productVariants(first: 1, query: "sku:#{sku}") {
          edges {
            node {
              id
              sku
            }
          }
        }
      }
    GRAPHQL
  
    client = ShopifyAPI::Clients::Graphql::Admin.new(session: session)
    response = client.query(query: query)
  
    variant = response.body.dig("data", "productVariants", "edges", 0, "node")
    variant ? variant["id"].split("/").last : nil
  end
end