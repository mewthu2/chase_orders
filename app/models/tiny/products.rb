class Tiny::Products
  class << self
    def list_all_products(kind, situacao, function, pagina = nil)
      case kind
      when 'lagoa_seca'
        token = ENV.fetch('TOKEN_TINY_PRODUCTION')
      when 'bh_shopping'
        token = ENV.fetch('TOKEN_TINY_PRODUCTION_BH_SHOPPING')
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

    def assert_stock
      token_lagoa_seca = ENV.fetch('TOKEN_TINY_PRODUCTION')
      token_bh_shopping = ENV.fetch('TOKEN_TINY_PRODUCTION_BH_SHOPPING')

      update_stock_for_products(Product.all, token_lagoa_seca, 'lagoa_seca')
      update_stock_for_products(Product.all, token_bh_shopping, 'bh_shopping')
    end

    private

    def update_stock_for_products(products, token, kind)
      products.each do |product|
        product_id = kind == 'lagoa_seca' ? product.tiny_lagoa_seca_product_id : product.tiny_bh_shopping_id
        stock_data = obtain_stock(product_id, token)
        stock_value = stock_data['status'] != 'Erro' && stock_data['produto'].key?('saldo') ? stock_data['produto']['saldo'] : nil

        puts "Estoque - #{stock_value}"
        puts "Tipo - #{kind}"

        case kind
        when 'lagoa_seca'
          product.update(stock_lagoa_seca: stock_value)
        when 'bh_shopping'
          product.update(stock_bh_shopping: stock_value)
        end

        print 'Dormindo 2 segundos...'
        sleep(1)
      end
    end

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
        if product.tiny_lagoa_seca_product_id.blank?
          product.update!(tiny_lagoa_seca_product_id: product_id)
        end
      when 'bh_shopping'
        if product.tiny_bh_shopping_id.blank?
          product.update!(tiny_bh_shopping_id: product_id)
        end
      end
    end

    def product_exists?(product, kind)
      case kind
      when 'lagoa_seca'
        product.tiny_lagoa_seca_product_id.present?
      when 'bh_shopping'
        product.tiny_bh_shopping_id.present?
      else
        false
      end
    end
  end
end
