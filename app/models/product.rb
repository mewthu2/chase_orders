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

  # Nota: os metodos somente utilizados em callbacks ou utilizados somente por essa
  #       propria classe deverao ser privados (remover essa anotacao)
end
