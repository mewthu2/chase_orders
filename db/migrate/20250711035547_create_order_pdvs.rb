class CreateOrderPdvs < ActiveRecord::Migration[7.2]
  def change
    create_table :order_pdvs do |t|
      t.references :user, null: false, foreign_key: true
      t.string :customer_name, null: false
      t.string :customer_email
      t.string :customer_phone
      t.string :customer_cpf
      t.string :address1
      t.string :city
      t.string :state
      t.string :zip
      t.string :store_type, null: false
      t.string :payment_method, null: false
      t.decimal :subtotal, precision: 10, scale: 2, null: false
      t.decimal :discount_amount, precision: 10, scale: 2, default: 0
      t.string :discount_reason
      t.decimal :total_price, precision: 10, scale: 2, null: false
      t.text :notes
      t.text :order_note
      t.string :status, default: 'pending'
      t.string :shopify_order_id
      t.string :shopify_order_number
      t.text :integration_error
      t.datetime :integrated_at
      t.integer :integration_attempts, default: 0

      t.timestamps
    end

    add_index :order_pdvs, :status
    add_index :order_pdvs, :shopify_order_id
    add_index :order_pdvs, :created_at
  end
end
