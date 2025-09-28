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
    (stock_lagoa_seca || 0) + 
    (stock_bh_shopping || 0) + 
    (stock_rj || 0) + 
    (stock_fortaleza_rio_mar || 0) + 
    (stock_porto_alegre_bourbon || 0) + 
    (stock_eldorado_sp || 0)
  end

  def stock_for_location(location)
    case location.to_s
    when 'lagoa_seca'
      stock_lagoa_seca || 0
    when 'bh_shopping'
      stock_bh_shopping || 0
    when 'rj'
      stock_rj || 0
    when 'fortaleza_rio_mar'
      stock_fortaleza_rio_mar || 0
    when 'porto_alegre_bourbon'
      stock_porto_alegre_bourbon || 0
    when 'eldorado_sp'
      stock_eldorado_sp || 0
    else
      0
    end
  end

  def update_stock_for_location(location, quantity)
    case location.to_s
    when 'lagoa_seca'
      update(stock_lagoa_seca: quantity)
    when 'bh_shopping'
      update(stock_bh_shopping: quantity)
    when 'rj'
      update(stock_rj: quantity)
    when 'fortaleza_rio_mar'
      update(stock_fortaleza_rio_mar: quantity)
    when 'porto_alegre_bourbon'
      update(stock_porto_alegre_bourbon: quantity)
    when 'eldorado_sp'
      update(stock_eldorado_sp: quantity)
    end
  end

  # Nota: os metodos somente utilizados em callbacks ou utilizados somente por essa
  #       propria classe deverao ser privados (remover essa anotacao)
end
