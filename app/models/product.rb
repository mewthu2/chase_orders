class Product < ApplicationRecord
  # Callbacks
  # Associacoes
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
end
