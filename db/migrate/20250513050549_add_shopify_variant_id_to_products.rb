class AddShopifyVariantIdToProducts < ActiveRecord::Migration[7.2]
  def change
    add_column :products, :shopify_variant_id, :string, after: :shopify_product_id
  end
end
