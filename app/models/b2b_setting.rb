# Configuração do atacado (uma linha só):
# - fixed_freight_value: frete fixo que o pedido recebe ao escolher "Frete fixo" (ajustável no pedido);
# - seamless_discount_percent / default_discount_percent: desconto sobre o preço de varejo que dá o preço
#   sugerido do item no pedido do atacado (Seamless = produto com "Seamless" no nome; o resto usa o padrão).
class B2bSetting < ApplicationRecord
  validates :fixed_freight_value, numericality: { greater_than_or_equal_to: 0 }
  validates :seamless_discount_percent, :default_discount_percent, numericality: { greater_than_or_equal_to: 0, less_than: 100 }

  def self.current
    first || create!(fixed_freight_value: 0)
  end

  def self.seamless?(product)
    product&.shopify_product_name.to_s.downcase.include?('seamless')
  end

  def discount_percent_for(product)
    self.class.seamless?(product) ? seamless_discount_percent : default_discount_percent
  end

  # Preço sugerido do atacado: varejo com o desconto da categoria do produto.
  def wholesale_price_for(product)
    return nil unless product&.price.present?

    (product.price.to_d * (100 - discount_percent_for(product)) / 100).round(2).to_f
  end
end
