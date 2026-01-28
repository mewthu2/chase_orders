class AddShopifyLocationIdToLocations < ActiveRecord::Migration[7.2]
  def change
    add_column :locations, :shopify_location_id, :string
    add_index  :locations, :shopify_location_id, unique: true
  end
end
