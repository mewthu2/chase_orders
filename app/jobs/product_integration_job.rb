class ProductIntegrationJob < ActiveJob::Base
  def perform(function, field, value, product)
    @field = field
    @value = value
    @product = product

    case function
    when 'update_product_cost'
      update_product_cost_on_tiny
    end
  end

  def update_product_cost_on_tiny
    Product.each do |product|
      tiny_product = Tiny::Products.find_product("739566362")
    end
  end
end
