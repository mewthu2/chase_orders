class ProductIntegrationJob < ActiveJob::Base
  def perform(function, product)
    @product = product

    case function
    when 'update_product_cost'
      update_product_cost_on_tiny(product)
    end
  end

  def update_product_cost_on_tiny(product)
    tiny_product = Tiny::Products.find_product(product.tiny_product_id)
    # atualiza preço custo:

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
    Tiny::Products.update_product(array)
  end
end
