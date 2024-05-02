class ProductIntegrationJob < ActiveJob::Base
  def perform(function, product, user)
    @product = product

    case function
    when 'update_product_cost'
      update_product_cost_on_tiny(product, user)
    end
  end

  def update_product_cost_on_tiny(product, user)
    ProductUpdate.transaction do
      tiny_product = Tiny::Products.find_product(product.tiny_product_id)
      # atualiza preço custo:
      product_update = ProductUpdate.create(product:,
                                            user:,
                                            field: 'cost',
                                            original_value: tiny_product['produto']['preco_custo'].to_f,
                                            modified_value: product.cost.to_f)
      array = {
        produtos: [
          {
            produto: {
              sequencia: 1,
              unidade: tiny_product['produto']['unidade'],
              id: tiny_product['produto']['id'],
              nome: tiny_product['produto']['nome'],
              codigo: tiny_product['produto']['codigo'],
              preco: tiny_product['produto']['preco'],
              origem: tiny_product['produto']['origem'],
              preco_custo: product.cost.to_f,
              preco_custo_medio: product.cost.to_f,
              situacao: tiny_product['produto']['situacao'],
              tipo: tiny_product['produto']['tipo']
            }
          }
        ]
      }
      json_string = Tiny::Products.update_product(array)
      data = JSON.parse(json_string)

      if data['retorno']['status'] == 'OK'
        product_update.update(kinds: 'success', json_return: data)
      else
        product_update.update(kinds: 'error', json_return: data)
      end
    end
  end
end
