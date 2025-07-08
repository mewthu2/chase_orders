class CreateLixnOrdersFromShopifyJob < ActiveJob::Base
  require 'uri'

  SHOPIFY_ORDER_REQUEST_LIMIT = 250

  # This job imports orders from Shopify to Lixn based on the specified kind.
  # @param kind [Symbol] The kind of shopping (e.g., :bh_shopping, :rj, :lagoa_seca).
  # @return [void]
  def perform(kind)
    start_at = Time.zone.now
    puts "Iniciando importação de pedidos da Shopify de (#{kind}) para Lixn... em #{start_at}"

    orders_request(kind)
    process_orders(kind)

    puts "Finalizando importação de pedidos da Shopify de (#{kind}) para Lixn em #{Time.zone.now - start_at}"
  end

  private
  
  # Sets up a Shopify session for the specified kind of shopping.
  # @param kind [Symbol] The kind of shopping (e.g., :bh_shopping, :rj, :lagoa_seca).
  # @return [ShopifyAPI::Auth::Session] The Shopify session for the specified kind.
  def setup_shopify_session(kind)
    return unless kind
    @setup_shopify_session ||= {}
    @setup_shopify_session[kind] ||= ShopifyAPI::Auth::Session.new(
      shop: ENV.fetch('SHOPIFY_STORE_DOMAIN'),
      access_token: token_by_kind(kind)
    )
  end

  # Returns the token for the specified kind of shopping.
  # @param kind [Symbol] The kind of shopping (e.g., :bh_shopping, :rj, :lagoa_seca).
  # @return [String] The token for the specified kind.
  def token_by_kind(kind = nil)
    # TO-TO Kinds needs to be defined for this store, this is just a example
    {
      bh_shopping: ENV.fetch('BH_SHOPPING_TOKEN_APP'),
      rj: ENV.fetch('BARRA_SHOPPING_TOKEN_APP'),
      lagoa_seca: ENV.fetch('LAGOA_SECA_TOKEN')
    }.with_indifferent_access[kind]
  end

  # Returns a REST Shopify instance for the specified kind of shopping.
  # @param kind [Symbol] The kind of shopping (e.g., :bh_shopping, :rj, :lagoa_seca).
  # @return [ShopifyAPI::Clients::Rest::Admin] The REST Shopify instance for the specified kind.
  def rest_shopify_instance(kind)
    @rest_shopify_instance ||= {}
    @rest_shopify_instance[kind] ||= ShopifyAPI::Clients::Rest::Admin.new(session: setup_shopify_session(kind))
  end

  # Returns the current orders array, initializing it if it doesn't exist.
  # @param kind [Symbol] The kind of shopping (e.g., :bh_shopping, :rj, :lagoa_seca).
  # @return [Array] The current orders for the specified kind.
  # @note This method caches the orders to avoid multiple requests for the same kind.
  def current_orders(kind)
    @current_orders ||= []
    @current_orders[kind] ||= []
  end

  # Returns the current full orders array, initializing it if it doesn't exist.
  # @param kind [Symbol] The kind of shopping (e.g., :bh_shopping, :rj, :lagoa_seca).
  # @return [Array] The current orders for the specified kind.
  # @note This method caches the orders to avoid multiple requests for the same kind.
  def current_full_orders(id)
    @current_orders ||= []
    @current_orders[id] ||= []
  end


  # Returns the orders from Shopify for the specified kind of shopping.
  # @param kind [Symbol] The kind of shopping (e.g., :bh_shopping, :rj, :lagoa_seca).
  # @return [Array] An array of orders fetched from Shopify.
  # @raise [ShopifyAPI::Errors::HttpResponseError] If there is an error fetching orders.
  def orders_request(kind)
    @response = rest_shopify_instance(kind).get(path: 'orders', query: rest_shopify_query)
    current_orders(kind).concat(@response.body['orders'])

    while (next_url = parse_next_page(@response))
      @response = rest_shopify_instance(kind).get(
        path: 'orders',
        query: rest_shopify_query(next_url: true, token: extract_next_page_token(next_url))
      )
      current_orders(kind).concat(@response.body['orders'])
    end
  rescue ShopifyAPI::Errors::HttpResponseError => e
    puts "Erro ao buscar pedidos da Shopify: #{e.message}" 
  end

  # Returns the query parameters for the Shopify REST API.
  # @param next_url [Boolean] Whether to include pagination parameters.
  # @param token [String, nil] The page info token for pagination.
  # @param id [Integer, nil] The specific order ID to fetch.
  # @return [Hash] The query parameters for the Shopify REST API.
  def rest_shopify_query(next_url: false, token: nil, id: nil)
    default_query = { path: 'orders', limit: SHOPIFY_ORDER_REQUEST_LIMIT, fields: 'id' }
    default_query.merge!(id:, fields: order_shopify_show_request_fields) if id

    return default_query.merge(status: 'any') unless next_url

    default_query.merge(page_info: token)
  end

  # Returns the fields to be requested for each order from Shopify.
  # @return [String] A comma-separated string of fields to be included in the order request.
  def order_shopify_show_request_fields
    'id,created_at,contact_email,phone,currency,current_subtotal_price,current_subtotal_price_set,
      current_total_discounts,current_total_discounts_set,current_total_duties_set,current_total_price,
      current_total_price_set,current_total_tax,financial_status,order_status_url,line_items'
  end

  # Parses the next page URL from the response headers.
  # @param response [ShopifyAPI::Response, nil] The response object from the Shopify API.
  # @return [String, nil] The next page URL if available, otherwise nil.
  def parse_next_page(response = nil)
    return unless response
    header_link = response.headers['link'].to_a.first
    return unless header_link.present?

    match = header_link.match(/<([^>]+)>;\s*rel="next"/)
    match && match[1]
  end

  # Extracts the next page token from the given URI.
  # @param uri [String] The URI containing the page info token.
  # @return [String] The page info token extracted from the URI.
  def extract_next_page_token(uri)
    CGI.parse(URI.parse(uri).query)['page_info'].first
  end

  # Creates or finds an attempt record for transferring a Shopify order to Lixn.
  # @param success_id [Integer] Indicates whether the transfer was successful by Lixn order id.
  # @param kind [Symbol] The kind of shopping (e.g., :bh_shopping, :rj, :lagoa_seca).
  # @return [Attempt] The created or updated Attempt record.
  def create_or_find_attempt(success_id:, kind:)
    Attempt.find_or_create_by(
      shopify_order_id: @attempt.shopify_order_id, kind: Attempt.kinds[:transfer_shopify_order_to_lixn]
    ).update!(
      status: success_id ? :error : :success,
      lixn_order_id: success_id,
      tracking: "#{kind}|#{success_id ? 'success' : 'error'}:",
      classification: success_id ? 'create_lixn_orders_from_shopify_job' : 'exception',
      message: "Importação de pedidos da Shopify para Lixn concluída com #{success_id ? 'successo' : 'falha'} para o tipo #{kind}.",
    )
  end

  # Finds an attempt record for transferring a Shopify order to Lixn.
  # @param id [Integer] The ID of the attempt to find.
  # @return [Attempt, nil] The Attempt record if found, otherwise nil.
  def attempt_orders(id:)
    @attempt = Attempt.find_by(id:, kinds: Attempt.kinds[:transfer_shopify_order_to_lixn])
  end

  # Processes the orders for the specified kind of shopping.
  # @param kind [Symbol] The kind of shopping (e.g., :bh_shopping, :rj, :lagoa_seca).
  def process_orders(kind)
    current_orders(kind).each do |order|
      next if attempt_orders(order['id'])&.status.to_s == 'success'

      current_full_orders(@attempt.shopify_order_id).concat(
        rest_shopify_instance(kind).get(
          path: 'orders', query: rest_shopify_query(id: @attempt.shopify_order_id)
        ).body['orders']
      )
    rescue ShopifyAPI::Errors::HttpResponseError => e
      puts "Erro ao buscar pedidos da Shopify: #{e.message}"
    ensure
      create_or_find_attempt(succes: create_lixn_order, kind:)
    end
  end

  # Sets up a Lixn session for importing orders.
  # This method uses the Savon client to connect to the Lixn API.
  # @return [Savon::Client] The Savon client configured for Lixn.
  def setup_lixn_session
    @setup_lixn_session ||= Savon.client(
      wsdl: ENV.fetch('LIXN_WEBSERVICE_DOMAIN'),
      basic_auth: [ENV.fetch('LIXN_WEBSERVICE_USER'),ENV.fetch('LIXN_WEBSERVICE_PASSWORD')],
      open_timeout: 10,
      read_timeout: 10,
      namespaces: {
        "xmlns:soapenv" => "http://schemas.xmlsoap.org/soap/envelope/",
        "xmlns:tem" => "http://tempuri.org/"
      },
      convert_request_keys_to: :none
    )
  end

  # Creates parameters for a Lixn order based on the Shopify order attempt.
  # @return [Hash] The parameters to be used for creating a Lixn order.
  # @note This method extracts relevant fields from the Shopify order attempt.
  # @note Params should include:
  #   :cnpj_emp, :id_portal, :cnpj_empresa, :doc_cliente,
  #   :data_documento, :documento, :items => [ { codigo_produto:, qtdeproduto:, preco_unitario:, posicao_item: , … }, … ],
  #   plus any optional fields (plano, valor_frete, reserva_estoque, obs, etc)
  def create_lixn_order_params
    current_full_order = current_full_orders(@attempt.shopify_order_id).first.with_indiffent_accesss
    @item_position = 0

    @params = {
      access_key: ENV.fetch('LIXN_ACCESS_KEY'),
      cnpj_emp: ENV.fetch('CNPJ_EMP'),
      id_portal: ENV.fetch('ID_PORTAL'),
      ws_user: ENV.fetch('LIXN_WEBSERVICE_USER'),
      ws_pass: ENV.fetch('LIXN_WEBSERVICE_PASSWORD'),
      transacao: @attempt.id,
      doc_cliente: '', # TO-DO request a different shopify api to get the customers data
      data_documento: Date.today.strftime('%Y-%m-%d'),
      documento: @attempt.shopify_order_id,
      items: current_full_order[:line_items].map do |item|
        { 
          codigo_produto: item['product_id'], qtdeproduto: item['quantity'],
          preco_unitario: item['price'].to_f / item['quantity'], posicao_item: @item_position += 1
        }
      end,
      obs: 'Importação de pedidos da Shopify para Lixn'
    }
  end

  # Builds each item’s Parameter list using @params
  def build_lixn_parameter_list
    @record = []
    @params.fetch(:items).each do |item|
      # common order header fields
      @record << { 'Name' => 'transacao', 'Value' => @params.fetch(:transacao) }
      @record << { 'Name' => 'cnpj_empresa', 'Value' => @params.fetch(:cnpj_empresa) }
      @record << { 'Name' => 'doc_cliente', 'Value' => @params.fetch(:doc_cliente) }
      @record << { 'Name' => 'data_documento','Value' => @params.fetch(:data_documento) }
      @record << { 'Name' => 'documento', 'Value' => @params.fetch(:documento) }
      # per‐item fields
      @record << { 'Name' => 'codigo_produto', 'Value' => item.fetch(:codigo_produto) }
      @record << { 'Name' => 'qtdeproduto', 'Value' => item.fetch(:qtdeproduto) }
      @record << { 'Name' => 'preco_unitario', 'Value' => item.fetch(:preco_unitario) }
      @record << { 'Name' => 'posicao_item', 'Value' => item.fetch(:posicao_item) }
      # tell Linx it’s an order, not just an orçamento
      @record << { 'Name' => 'pedido', 'Value' => 1 }
      # optional flags
      @record << { 'Name' => 'obs', 'Value' => @params[:obs] }
    end
  end

  
  # Builds lixn selector using @params
  def build_lixn_selector_params
    @selector = [
      { 'Name' => 'chave', 'Value' => @params.fetch(:access_key) },
      { 'Name' => 'cnpjEmp', 'Value' => @params.fetch(:cnpj_emp) },
      { 'Name' => 'IdPortal', 'Value' => @params.fetch(:id_portal) }
    ]
  end

  # Builds lixn savon message using @selector and @record
  # @return [Hash]
  def lixn_savon_message
    {
      'tem:request' => {
        'linx:ParamsSeletorDestino' => {
          'linx1:CommandParameter' => @selector.map { |p| { '@Name' => p['Name'], '@Value' => p['Value'] } }
        },
        'linx:Tabela' => {
          'linx2:Comando'  => 'LinxCadastraOrcamentos',
          'linx2:Registros'=> {
            'linx:Registros' => {
              'linx:Colunas' => {
                'linx1:CommandParameter' => @record.map { |p| { '@Name' => p['Name'], '@Value' => p['Value'] } }
              }
            }
          }
        },
        'linx:UserAuth' => {
          'linx2:User' => ENV.fetch('LIXN_WEBSERVICE_USER'), 'linx2:Pass' => ENV.fetch('LIXN_WEBSERVICE_PASSWORD')
        }
      }
    }
  end

  # Create lixn order
  # @return [String, nil] Lixn_order_id
  def create_lixn_order
    create_lixn_order_params
    build_lixn_parameter_list
    build_lixn_selector_params

    response = setup_lixn_session.call(:importar, message: lixn_savon_message)
    result = response.body.dig(:importar_response, :importar_result)
    return unless result[:success]

    result.dig(:documentos, :int).first.to_i
  rescue Savon::Error => e
    Rails.logger.error "Linx order creation failed: #{e.message}"
  end
end