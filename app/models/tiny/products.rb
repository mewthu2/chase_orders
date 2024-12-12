class Tiny::Products
  class << self
    def list_all_products(kind, situacao, function, pagina = nil)
      case kind
      when 'lagoa_seca'
        token = ENV.fetch('TOKEN_TINY_PRODUCTION')
      when 'bh_shopping'
        token = ENV.fetch('TOKEN_TINY_PRODUCTION_BH_SHOPPING')
      when 'rj'
        token = ENV.fetch('TOKEN_TINY_PRODUCTION_RJ')
      end

      response = get_products_response(situacao, token, pagina)

      total = []

      if response['numero_paginas'].present? && response['numero_paginas'].positive?
        (1..response[:numero_paginas]).each do |page_number|
          total << get_products_response(situacao, token, page_number)
        end
      else
        total << response
      end

      case function
      when 'update_products_situation'
        total.each do |list_products|
          find_or_create_product(list_products['produtos'], kind)
        end
      else
        total
      end
    end

    def obtain_stock(product_id, token)
      response = JSON.parse(HTTParty.get(ENV.fetch('OBTER_ESTOQUE'),
                                         query: { token:,
                                                  formato: 'json',
                                                  id: product_id }))
      response.with_indifferent_access[:retorno]
    end

    def find_product(product_id, token)
      response = JSON.parse(HTTParty.get(ENV.fetch('OBTER_PRODUTO'),
                                         query: { token:,
                                                  formato: 'json',
                                                  id: product_id }))
      response.with_indifferent_access[:retorno]
    end

    def update_product(products, token)
      HTTParty.post(ENV.fetch('ALTERAR_PRODUTO'), body: {
                                token:,
                                formato: 'json',
                                produto: products.to_json
                              }, headers: {
                                'Cookie' => '__cf_bm=b7051RRfkZC9AV_x5yhIR1YwwFKbCBPhyfHyy6UkYiA-1714414033-1.0.1.1-yM8S6uVPTUHPbqgBucg.8Ar9U5shYRd5zAGggCvd88XerAZtCE9ti1Whloyh5bUX2DNyQQN92b7G1gORyv2Dmw',
                                'Content-Type' => 'application/x-www-form-urlencoded'
                              })
    end

    private

    def get_products_response(situacao, token, pagina = nil)
      response = JSON.parse(HTTParty.get(ENV.fetch('PRODUTOS_PESQUISA'),
                                         query: {
                                          token:,
                                          formato: 'json',
                                          situacao:,
                                          pagina:
                                        }))
      response.with_indifferent_access[:retorno]
    end

    def find_or_create_product(products, kind)
      products.each do |tiny_product_data|
        next unless tiny_product_data.key?('produto')

        product_data = tiny_product_data['produto']
        next if product_data['codigo'] == product_data['nome']

        product = Product.find_or_create_by(sku: product_data['codigo'])
        assign_tiny_product_id(product, kind, product_data['id'])
      end
    end

    def assign_tiny_product_id(product, kind, product_id)
      case kind
      when 'lagoa_seca'
        product.update!(tiny_lagoa_seca_product_id: product_id) if product.tiny_lagoa_seca_product_id.blank?
      when 'bh_shopping'
        product.update!(tiny_bh_shopping_id: product_id) if product.tiny_bh_shopping_id.blank?
      when 'rj'
        product.update!(tiny_rj_id: product_id) if product.tiny_rj_id.blank?
      end
    end

    def product_exists?(product, kind)
      case kind
      when 'lagoa_seca'
        product.tiny_lagoa_seca_product_id.present?
      when 'bh_shopping'
        product.tiny_bh_shopping_id.present?
      when 'rj'
        product.tiny_rj_idpresent?
      else
        false
      end
    end
  end
end
