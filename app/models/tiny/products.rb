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

    def update_product(product)
      response = JSON.parse(HTTParty.get(ENV.fetch('ALTERA_PRODUTO'),
                                         query: { token: ENV.fetch('TOKEN_TINY_PRODUCTION'),
                                                  formato: 'json',
                                                  produto: product }))
      response.with_indifferent_access[:retorno]
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
                                  tiny_product_id: tiny_product_data['produto']['id'])
      end
    end
  end
end
