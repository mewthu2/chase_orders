class AddShopifyVariantIdToProducts < ActiveRecord::Migration[7.0]
  def change
    add_column :products, :shopify_variant_id, :string, after: :shopify_product_id
  end
end
