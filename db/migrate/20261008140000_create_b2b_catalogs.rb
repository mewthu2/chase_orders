class CreateB2bCatalogs < ActiveRecord::Migration[7.2]
  def change
    create_table :b2b_catalogs do |t|
      t.string :title, null: false
      t.integer :kind, null: false, default: 0
      t.references :client, foreign_key: true
      t.integer :status, null: false, default: 0
      t.string :public_token, null: false
      t.text :notes
      t.references :user, null: false, foreign_key: true
      t.datetime :stock_refreshed_at
      t.timestamps
    end
    add_index :b2b_catalogs, :public_token, unique: true

    create_table :b2b_catalog_products do |t|
      t.references :b2b_catalog, null: false, foreign_key: true
      t.string :shopify_product_id
      t.string :style_name, null: false
      t.string :color_name, null: false, default: ''
      t.integer :position, null: false, default: 0
      t.json :image_urls
      t.timestamps
    end
    add_index :b2b_catalog_products, :shopify_product_id

    create_table :b2b_catalog_variants do |t|
      t.references :b2b_catalog_product, null: false, foreign_key: true
      t.string :sku, null: false
      t.string :size, null: false
      t.integer :position, null: false, default: 0
      t.integer :available, null: false, default: 0
      t.integer :availability, null: false, default: 2
      t.timestamps
    end
    add_index :b2b_catalog_variants, :sku

    create_table :b2b_catalog_orders do |t|
      t.references :b2b_catalog, null: false, foreign_key: true
      t.string :customer_name, null: false
      t.string :customer_registration
      t.references :client, foreign_key: true
      t.integer :status, null: false, default: 0
      t.references :b2b_order, foreign_key: true
      t.datetime :submitted_at
      t.string :last_edited_by
      t.string :edit_token, null: false
      t.timestamps
    end
    add_index :b2b_catalog_orders, [:b2b_catalog_id, :customer_registration], unique: true, name: 'index_b2b_catalog_orders_on_catalog_and_registration'
    add_index :b2b_catalog_orders, :edit_token, unique: true

    create_table :b2b_catalog_order_items do |t|
      t.references :b2b_catalog_order, null: false, foreign_key: true
      t.references :b2b_catalog_variant, null: false, foreign_key: true
      t.integer :quantity, null: false
      t.timestamps
    end
  end
end
