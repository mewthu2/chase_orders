module Tiny::Products
  module_function

  def list_all_products(kind, situacao, function, pagina = nil)
    token = fetch_token_for_kind(kind)

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
      assert_stock
      assert_cost if kind == 'tiny_2'
    else
      total
    end
  end

  def self.obtain_stock(product_id, token)
    response = JSON.parse(HTTParty.get(ENV.fetch('OBTER_ESTOQUE'),
                                       query: { token:,
                                                formato: 'json',
                                                id: product_id }))
    response.with_indifferent_access[:retorno]
  end

  def self.find_product(product_id, token)
    response = JSON.parse(HTTParty.get(ENV.fetch('OBTER_PRODUTO'),
                                       query: { token:,
                                                formato: 'json',
                                                id: product_id }))
    response.with_indifferent_access[:retorno]
  end

  def self.update_product(products, token)
    HTTParty.post(ENV.fetch('ALTERAR_PRODUTO'), body: {
                                  token:,
                                  formato: 'json',
                                  produto: products.to_json
                                }, headers: {
                                  'Cookie' => '__cf_bm=b7051RRfkZC9AV_x5yhIR1YwwFKbCBPhyfHyy6UkYiA-1714414033-1.0.1.1-yM8S6uVPTUHPbqgBucg.8Ar9U5shYRd5zAGggCvd88XerAZtCE9ti1Whloyh5bUX2DNyQQN92b7G1gORyv2Dmw',
                                  'Content-Type' => 'application/x-www-form-urlencoded'
                                })
  end

  def self.assert_cost
    token_tiny2 = ENV.fetch('TOKEN_TINY2_PRODUCTION')

    update_cost_for_products(Product.all, token_tiny2, 'tiny_2')
  end

  def self.update_cost_for_products(products, token, kind)
    products.each do |product|
      product_id = product.tiny_2_id
      next unless product_id.present?

      product_data = find_product(product_id, token)
      cost_data = product_data['produtos'].first['produto'] rescue nil

      next unless cost_data&.key?('preco_custo_medio')

      cost_value = cost_data['preco_custo_medio'].to_f
      puts "Custo médio - #{cost_value}"
      puts "Tipo - #{kind}"

      product.update(cost: cost_value) if cost_value.positive?

      print 'Dormindo 2 segundos...'
      sleep(0.5)
    end
  end

  def self.assert_stock
    token_lagoa_seca = ENV.fetch('TOKEN_TINY_PRODUCTION')
    token_bh_shopping = ENV.fetch('TOKEN_TINY_PRODUCTION_BH_SHOPPING')
    token_rj = ENV.fetch('TOKEN_TINY_PRODUCTION_RJ')
    token_tiny2 = ENV.fetch('TOKEN_TINY2_PRODUCTION')

    update_stock_for_products(Product.all, token_lagoa_seca, 'lagoa_seca')
    update_stock_for_products(Product.all, token_bh_shopping, 'bh_shopping')
    update_stock_for_products(Product.all, token_rj, 'rj')
    update_stock_for_products(Product.all, token_tiny2, 'token_tiny_2')
  end

  def self.update_stock_for_products(products, token, kind)
    six_hours_ago = 24.hours.ago
    filtered_products = products.where('updated_at < ?', six_hours_ago)

    filtered_products.each do |product|
      case kind
      when 'lagoa_seca'
        product_id = product.tiny_lagoa_seca_product_id
      when 'bh_shopping'
        product_id = product.tiny_bh_shopping_id
      when 'rj'
        product_id = product.tiny_rj_id
      end

      stock_data = obtain_stock(product_id, token)
      stock_value = stock_data['status'] != 'Erro' && stock_data['produto'].key?('saldo') ? stock_data['produto']['saldo'] : nil

      puts "Estoque - #{stock_value}"
      puts "Tipo - #{kind}"

      case kind
      when 'lagoa_seca'
        product.update(stock_lagoa_seca: stock_value)
      when 'bh_shopping'
        product.update(stock_bh_shopping: stock_value)
      when 'rj'
        product.update(stock_rj: stock_value)
      end

      print 'Dormindo 0.5 segundos...'
      sleep(0.5)
    end
  end

  def self.get_products_response(situacao, token, pagina = nil)
    response = JSON.parse(HTTParty.get(ENV.fetch('PRODUTOS_PESQUISA'),
                                       query: {
                                        token:,
                                        formato: 'json',
                                        situacao:,
                                        pagina:
                                      }))
    response.with_indifferent_access[:retorno]
  end

  def self.find_or_create_product(products, kind)
    products.each do |tiny_product_data|
      next unless tiny_product_data.key?('produto')

      product_data = tiny_product_data['produto']
      next if product_data['codigo'] == product_data['nome']

      product = Product.find_or_create_by(sku: product_data['codigo'])
      assign_tiny_product_id(product, kind, product_data['id'])
    end
  end

  def self.assign_tiny_product_id(product, kind, product_id)
    case kind
    when 'lagoa_seca'
      product.update!(tiny_lagoa_seca_product_id: product_id) if product.tiny_lagoa_seca_product_id.blank?
    when 'bh_shopping'
      product.update!(tiny_bh_shopping_id: product_id) if product.tiny_bh_shopping_id.blank?
    when 'rj'
      product.update!(tiny_rj_id: product_id) if product.tiny_rj_id.blank?
    when 'tiny_2'
      product.update!(tiny_2_id: product_id) if product.tiny_2_id.blank?
    end
  end

  def self.fetch_token_for_kind(kind)
    case kind
    when 'lagoa_seca'
      ENV.fetch('TOKEN_TINY_PRODUCTION')
    when 'bh_shopping'
      ENV.fetch('TOKEN_TINY_PRODUCTION_BH_SHOPPING')
    when 'rj'
      ENV.fetch('TOKEN_TINY_PRODUCTION_RJ')
    when 'tiny_3'
      ENV.fetch('TOKEN_TINY3_PRODUCTION')
    when 'tiny_2'
      ENV.fetch('TOKEN_TINY2_PRODUCTION')
    else
      raise "Unknown kind: #{kind}"
    end
  end
end
