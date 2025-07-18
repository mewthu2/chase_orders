module ShopifyLinx
  class CreateLinxOrdersFromShopifyJob < BaseShopifyLinxJob
    require 'uri'

    SHOPIFY_ORDER_REQUEST_LIMIT = 250

    # This job imports orders from Shopify to LINX based on the specified kind.
    # @param kind [Symbol] The kind of shopping (e.g., :bh_shopping, :rj, :lagoa_seca).
    # @return [void]
    def perform(kind)
      start_at = Time.zone.now
      puts "Iniciando importação de pedidos da Shopify de (#{kind}) para LINX... em #{start_at}"

      orders_request(kind)
      process_orders(kind)

      puts "Finalizando importação de pedidos da Shopify de (#{kind}) para LINX em #{Time.zone.now - start_at}"
    end

    def call_consulta_transportadores
      client = LinxErp::SavonClient.new
      response = client.consulta_transportadores(
        chave:             '84a5d15-b051-4140-915d-b94f1e52a615',
        cnpj_emp:          '20203489000106',
        cod_transportador: '2147483647'
      )

      raw = response.http.body
      raw.sub!("\xEF\xBB\xBF".b, ''.b)
      raw.force_encoding('ISO-8859-1')
      utf8 = raw.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
      puts 'x5'*20, utf8
    end

    def consulta_pedido_status
      client = LinxErp::SavonClient.new
      response = client.consulta_pedido_status(
        chave:     '84a5d15-b051-4140-915d-b94f1e52a615',
        cnpj_emp:  '20203489000106',
        timestamp: '8146561520'
      )

      raw = response.http.body
      raw.sub!("\xEF\xBB\xBF".b, ''.b)
      raw.force_encoding('ISO-8859-1')
      utf8 = raw.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
      puts 'x5'*20, utf8
    end

    private

    # Returns the fields to be requested for each order from Shopify.
    # @return [String] A comma-separated string of fields to be included in the order request.
    def order_shopify_show_request_fields
      'id,created_at,contact_email,phone,currency,current_subtotal_price,current_subtotal_price_set,
        current_total_discounts,current_total_discounts_set,current_total_duties_set,current_total_price,
        current_total_price_set,current_total_tax,financial_status,order_status_url,line_items'
    end
  end
end