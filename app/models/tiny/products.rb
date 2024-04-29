class Tiny::Products
  class << self
    def list_all_products(situacao, function, pagina = nil)
      response = get_products_response(situacao, pagina)

      total = []

      if response['numero_paginas'].present? && response['numero_paginas'].positive?
        (1..response[:numero_paginas]).each do |page_number|
          total << get_products_response(situacao, page_number)
        end
      else
        total << response
      end

      case function
      when 'update_products_situation'
        total.each do |list_products|
          find_or_create_product(list_products['produtos'])
        end
      else total
      end
    end

    def find_product(product_id)
      response = JSON.parse(HTTParty.get(ENV.fetch('OBTER_PRODUTO'),
                                         query: { token: ENV.fetch('TOKEN_TINY_PRODUCTION'),
                                                  formato: 'json',
                                                  id: product_id }))
      response.with_indifferent_access[:retorno]
    end

    def update_product(products)
      HTTParty.post(ENV.fetch('ALTERAR_PRODUTO'), body: {
                                token: ENV.fetch('TOKEN_TINY_PRODUCTION'),
                                formato: 'json',
                                produto: products.to_json
                              }, headers: {
                                'Cookie' => '__cf_bm=b7051RRfkZC9AV_x5yhIR1YwwFKbCBPhyfHyy6UkYiA-1714414033-1.0.1.1-yM8S6uVPTUHPbqgBucg.8Ar9U5shYRd5zAGggCvd88XerAZtCE9ti1Whloyh5bUX2DNyQQN92b7G1gORyv2Dmw',
                                'Content-Type' => 'application/x-www-form-urlencoded'
                              })
    end

    private

    def get_products_response(situacao, pagina = nil)
      response = JSON.parse(HTTParty.get(ENV.fetch('PRODUTOS_PESQUISA'),
                                         query: {
                                          token: ENV.fetch('TOKEN_TINY_PRODUCTION'),
                                          formato: 'json',
                                          situacao:,
                                          pagina:
                                        }))
      response.with_indifferent_access[:retorno]
    end

    def find_or_create_product(products)
      products.each do |tiny_product_data|
        next if tiny_product_data['produto']['codigo'] == tiny_product_data['produto']['nome']
        Product.find_or_create_by(sku: tiny_product_data['produto']['codigo'],
                                  shopify_product_name: tiny_product_data['produto']['nome'],
                                  tiny_product_id: tiny_product_data['produto']['id'])
      end
    end
  end
end
