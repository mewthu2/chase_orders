class CreateDiscounts < ActiveRecord::Migration[7.0]
  def change
    create_table :discounts do |t|
      t.string :shopify_node_id, null: false
      t.string :shopify_price_rule_id
      
      t.string :code, null: false
      t.string :title, null: false
      t.text :summary
      
      t.boolean :is_active, default: true
      t.boolean :is_expired, default: false
      t.string :status, default: 'ACTIVE'
      
      t.datetime :starts_at
      t.datetime :ends_at
      t.datetime :shopify_created_at
      t.datetime :shopify_updated_at
      
      t.string :discount_type
      t.decimal :discount_value, precision: 10, scale: 4
      t.string :currency_code, default: 'BRL'
      t.string :applies_to
      
      t.decimal :min_purchase_amount, precision: 10, scale: 2
      t.integer :min_quantity
      
      t.string :customer_eligibility, default: 'Todos os clientes'
      t.integer :usage_limit
      t.integer :usage_count, default: 0
      t.boolean :one_per_customer, default: false
      
      t.boolean :combines_with_product, default: false
      t.boolean :combines_with_shipping, default: false
      t.boolean :combines_with_order, default: false
      
      t.json :shopify_data
      
      t.datetime :last_synced_at
      t.boolean :needs_sync, default: false

      t.timestamps
    end

    add_index :discounts, :shopify_node_id, unique: true
    add_index :discounts, :code
    add_index :discounts, :is_active
    add_index :discounts, :is_expired
    add_index :discounts, :starts_at
    add_index :discounts, :ends_at
    add_index :discounts, :last_synced_at
    add_index :discounts, :needs_sync
  end
end
