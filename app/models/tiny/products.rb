module Tiny::Products
  module_function

  def list_all_products(kind, situacao, function, pagina = nil)
    token = fetch_token_for_kind(kind)

    initial_response = get_products_response(situacao, token, pagina)
    total = [initial_response]

    if initial_response['numero_paginas'].to_i > 1
      total += (2..initial_response['numero_paginas']).map do |page_number|
        get_products_response(situacao, token, page_number)
      end
    end

    case function
    when 'update_products_situation'
      total.each do |list_products|
        find_or_create_products(list_products['produtos'], kind) if list_products['produtos'].present?
      end

      assert_stock(kind)
      assert_cost if kind == 'tiny_2'

      { status: :success, processed_products: total.sum { |r| r['produtos']&.size || 0 } }
    else
      total
    end
  rescue StandardError => e
    { status: :error, message: e.message }
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

    products = Product.select(:id, :tiny_2_id, :cost, :updated_at)
                      .where('updated_at < ?', 24.hours.ago)
                      .where.not(tiny_2_id: nil)

    update_cost_for_products(products, token_tiny2, 'tiny_2')
  end

  def self.update_cost_for_products(products, token, kind)
    products.find_each(batch_size: 100) do |product|
      product_data = find_product(product.tiny_2_id, token)
      cost_data = product_data.dig('produtos', 0, 'produto') if product_data

      next unless cost_data&.key?('preco_custo_medio')

      cost_value = cost_data['preco_custo_medio'].to_f

      if cost_value.positive?
        puts "Atualizando produto #{product.id} | Custo médio: #{cost_value} | Tipo: #{kind}"
        product.update_columns(cost: cost_value)
      end

      sleep(0.5)
    rescue StandardErrore => e
      Rails.logger.error "Erro ao atualizar custo do produto #{product.id}: #{e.message}"
      next
    end
  end

  def self.assert_stock(kind)
    token = fetch_token_for_kind(kind)

    products = Product.select(:id, :tiny_lagoa_seca_product_id, :tiny_bh_shopping_id, :tiny_rj_id,
                              :stock_lagoa_seca, :stock_bh_shopping, :stock_rj, :updated_at)
                      .where('updated_at < ?', 24.hours.ago)

    update_stock_for_products(products, token, kind)
  end

  def self.update_stock_for_products(products, token, kind)
    products.each do |product|
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

  def self.find_or_create_products(products, kind)
    return unless products.present?

    product_codes = products.filter_map do |tiny_product_data|
      product_data = tiny_product_data['produto'] rescue next
      product_data['codigo'] if product_data['codigo'] != product_data['nome']
    end.compact

    existing_products = Product.where(sku: product_codes).index_by(&:sku)

    products.each do |tiny_product_data|
      next unless tiny_product_data.key?('produto')

      product_data = tiny_product_data['produto']
      next if product_data['codigo'] == product_data['nome']

      product = existing_products[product_data['codigo']] || Product.create!(sku: product_data['codigo'])
      assign_tiny_product_id(product, kind, product_data['id'])
    end
  end

  def self.assign_tiny_product_id(product, kind, product_id)
    field_mapping = {
      'lagoa_seca' => :tiny_lagoa_seca_product_id,
      'bh_shopping' => :tiny_bh_shopping_id,
      'rj' => :tiny_rj_id,
      'tiny_2' => :tiny_2_id
    }

    field = field_mapping[kind]
    return unless field

    product.update!(field => product_id) if product[field].blank?
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
