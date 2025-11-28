class Product < ApplicationRecord
  # Callbacks
  # Associacoes
  has_many :product_updates
  # Validacoes

  # Escopos
  add_scope :search do |value|
    where('products.id LIKE :valor OR
           products.sku LIKE :valor OR
           products.shopify_inventory_item_id LIKE :valor OR
           products.cost LIKE :valor', valor: "#{value}%")
  end
  # Metodos estaticos
  # Metodos publicos
  # Metodos GET
  # Metodos SET
  scope :with_stock, -> { where('stock_lagoa_seca > 0 OR stock_bh_shopping > 0 OR stock_rj > 0 OR stock_fortaleza_rio_mar > 0 OR stock_porto_alegre_bourbon > 0 OR stock_eldorado_sp > 0') }
  scope :out_of_stock, -> { where(stock_lagoa_seca: 0, stock_bh_shopping: 0, stock_rj: 0, stock_fortaleza_rio_mar: 0, stock_porto_alegre_bourbon: 0, stock_eldorado_sp: 0) }

  def total_stock
    %i[
      stock_lagoa_seca
      stock_bh_shopping
      stock_rj
      stock_fortaleza_rio_mar
      stock_porto_alegre_bourbon
      stock_eldorado_sp
      stock_shopping_analia_franco
      stock_iguatemi_campinas
    ].sum { |field| self[field].to_i }
  end

  def stock_for_location(location)
    self["stock_#{location}"].to_i
  end

  def update_stock_for_location(location, quantity)
    update("stock_#{location}" => quantity)
  end
end
