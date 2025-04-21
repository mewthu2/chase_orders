def create_fulfilled_order(kind, response)
  case kind
  when 'bh_shhopping'
    location_id = 72286699594
  end

  session = ShopifyAPI::Auth::Session.new(
    shop: 'chasebrasil.myshopify.com',
    access_token: ENV.fetch('BH_SHOPPING_TOKEN_APP')
  )

  pedido = response['pedido']
  cliente = pedido['cliente']

  # Preparar dados do cliente
  nome_completo = cliente['nome'] || 'Cliente Shopify'
  nomes = nome_completo.strip.split
  first_name = nomes.first
  last_name = nomes[1..].join(' ') if nomes.size > 1

  # Gerar telefone único
  customer_phone = if cliente['fone'].present?
                    generate_unique_phone(cliente['fone'], session)
                  else
                    generate_unique_phone(nil, session)
                  end

  # Construir endereço
  endereco = build_address_graphql(cliente, customer_phone)

  # Construir line items melhorados com variant_id
  line_items = pedido['itens'].map do |item|
    sku = item.dig('item', 'codigo') || ''
    variant_id = find_variant_id_by_sku(session, sku)

    line_item = {
      "quantity" => item.dig('item', 'quantidade').to_i,
      "originalUnitPrice" => item.dig('item', 'valor_unitario').to_f,
      "taxable" => false,
      "title" => item.dig('item', 'descricao') || 'Produto sem nome'
    }

    # Adiciona variantId se encontrado
    line_item["variantId"] = "gid://shopify/ProductVariant/#{variant_id}" if variant_id

    line_item
  end

  # PASSO 1: Criar draft order
  draft_order = create_draft_order(
    session:,
    line_items:,
    cliente:,
    customer_phone:,
    endereco:,
    pedido:
  )

  complete_draft_order_rest(
    session:,
    draft_order_id: draft_order['id'].split('/').last,
    location_id:
  )

  return nil unless draft_order
end

# Método para encontrar variant_id por SKU
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
# Métodos auxiliares para cada passo
def create_draft_order(session:, line_items:, cliente:, customer_phone:, endereco:, pedido:)
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

  # Formatar CPF/CNPJ (manter pontuação conforme padrão brasileiro)
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
      "key" => "TAX_CREDENTIAL_BR",
      "value" => formatted_cpf
    }
  end

  # Preparar input com desconto
  input = {
    "lineItems" => line_items,
    "email" => cliente['email'].present? ? cliente['email'] : "sememail_#{SecureRandom.hex(4)}@dominiofalso.com",
    "phone" => format_phone_for_shopify(customer_phone),
    "shippingAddress" => endereco,
    "billingAddress" => endereco,
    "note" => cliente['obs'] || '',
    "tags" => pedido['nome_vendedor'],
    "localizedFields" => localized_fields
  }

  if pedido['valor_desconto'].to_f > 0
    input["appliedDiscount"] = {
      "value" => pedido['valor_desconto'].to_f,
      "valueType" => "FIXED_AMOUNT",
      "title" => "Desconto comercial"
    }
  end

  client = ShopifyAPI::Clients::Graphql::Admin.new(session: session)
  response = client.query(query: mutation, variables: { input: input })

  if response.body['errors'] || response.body.dig('data', 'draftOrderCreate', 'userErrors').any?
    puts "Erro ao criar draft order: #{response.body['errors'] || response.body.dig('data', 'draftOrderCreate', 'userErrors')}"
    nil
  else
    draft_order = response.body.dig('data', 'draftOrderCreate', 'draftOrder')
    puts "Draft order criado: #{draft_order['name']}"
    puts "CPF registrado: #{draft_order.dig('localizedFields', 'edges', 0, 'node', 'value')}"
    puts "Desconto aplicado: #{draft_order.dig('appliedDiscount', 'value')}" if draft_order['appliedDiscount']
    draft_order
  end
end

def complete_draft_order_rest(session:, draft_order_id:, location_id: nil)
  client = ShopifyAPI::Clients::Rest::Admin.new(session: session)

  begin
    response = client.get(path: "draft_orders/#{draft_order_id}.json")
    draft_order = response.body['draft_order']
    return puts("Draft order not found") unless draft_order

    # Usa os line_items diretamente
    line_items = draft_order['line_items']

    # Prepara dados do pedido
    order_data = {
      order: {
        email: draft_order['email'],
        send_receipt: false,
        send_fulfillment_receipt: false,
        line_items: line_items,
        customer: { id: draft_order['customer']['id'] },
        shipping_address: draft_order['shipping_address'],
        billing_address: draft_order['billing_address'],
        note: "#{draft_order['note']}",
        tags: "Gerencia",
        financial_status: 'paid',
        transactions: [
          {
            kind: 'sale',
            status: 'success',
            amount: draft_order['total_price']
          }
        ],
        # Aqui está o desconto aplicado diretamente
        total_discounts: draft_order['applied_discount'] ? draft_order['applied_discount']['amount'] : '0.0',
        subtotal_price: draft_order['subtotal_price'] ? (draft_order['subtotal_price'].to_f - draft_order['applied_discount']['amount'].to_f) : draft_order['subtotal_price']
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
          # Se for possível mover para a nova localização
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
              puts e.response.body
            end
          end

          # Cria o fulfillment
          begin
            client.post(
              path: "fulfillments.json",
              body: {
                fulfillment: {
                  message: "Pedido entregue em mãos.",
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
            puts e.response.body
          end
        end
      rescue ShopifyAPI::Errors::HttpResponseError => e
        puts "Erro ao buscar fulfillment_orders: #{e.message}"
        puts e.response.body
      end
    end

    {
      'id' => order['id'],
      'draft_order_id' => draft_order_id,
      'location_id' => location_id
    }
  rescue ShopifyAPI::Errors::HttpResponseError => e
    puts "Error: #{e.message}"
    puts e.response.body
    nil
  end
end

def format_phone_for_shopify(phone)
  return nil if phone.nil? || phone.empty?
  
  # Remove todos os caracteres não numéricos
  cleaned_phone = phone.gsub(/\D/, '')
  
  # Verifica se já tem código do país (55 para Brasil)
  if cleaned_phone.start_with?('55')
    "+#{cleaned_phone}"
  elsif cleaned_phone.start_with?('0')
    # Remove o 0 inicial se existir
    "+55#{cleaned_phone[1..-1]}"
  else
    # Assume que é um número brasileiro sem código do país
    "+55#{cleaned_phone}"
  end
end

def generate_unique_phone(original_phone, session)
  return '' if original_phone.blank?

  base_phone = format_phone_number(original_phone)

  return base_phone if phone_unique?(base_phone, session)

  base_digits = base_phone.gsub('+', '')

  # Extrai prefixo fixo (ex: +5511) e sufixo numérico (últimos 8 dígitos)
  prefix = base_digits[0..4]   # +55 DDD 9
  number = base_digits[5..-1]  # os 8 últimos dígitos do número

  3.times do |i|
    # Incrementa um valor nos últimos dígitos para gerar variações válidas
    new_number = (number.to_i + i + 1).to_s.rjust(8, '0')
    unique_phone = "+#{prefix}#{new_number}"

    return unique_phone if phone_unique?(unique_phone, session)
  end

  # Fallback com número totalmente aleatório, sempre dentro do padrão
  random_number = SecureRandom.rand(10_000_000..99_999_999)
  "+#{prefix}#{random_number}"
end

def format_phone_number(phone)
  return nil unless phone.present?

  cleaned = phone.gsub(/\D/, '')

  case cleaned.size
  when 11, 10 then "+55#{cleaned}"
  when 8 then "+5511#{cleaned}"
  else "+55#{cleaned}"
  end
end

def phone_unique?(phone, session)
  return false unless phone.present?

  # Search for customers with this phone
  customers = ShopifyAPI::Customer.all(
    session:,
    phone:,
    limit: 1
  )

  customers.empty?
rescue
  false
end

def build_address_graphql(cliente, phone = nil)
  phone ||= format_phone_number(cliente['fone'])

  {
    "address1" => [cliente['endereco'], cliente['numero']].compact.join(', '),
    "address2" => cliente['complemento'] || '',
    "city" => cliente['cidade'] || 'Cidade não informada',
    "province" => cliente['uf'] || 'SP',
    "country" => 'BR',
    "zip" => cliente['cep']&.gsub(/\D/, '') || '00000000',
    "firstName" => cliente['nome'].split.first,
    "lastName" => cliente['nome'].split[1..].join(' '),
    "phone" => phone,
    "company" => cliente['nome_fantasia'] || ''
  }
end







