# Financeiro (Etapa 1): consultores, parcelas dos pedidos de atacado e percentuais de comissão por mês.
# Só acrescenta: pode rodar a qualquer momento.
class CreateFinanceTables < ActiveRecord::Migration[8.1]
  def change
    create_table :consultants, if_not_exists: true do |t|
      t.string :name, null: false
      t.string :document
      t.string :phone
      t.string :email
      t.string :pix_key
      t.boolean :active, null: false, default: true
      t.timestamps
    end

    add_reference :b2b_orders, :consultant, foreign_key: true, if_not_exists: true

    create_table :b2b_order_payments, if_not_exists: true do |t|
      t.references :b2b_order, null: false, foreign_key: true
      t.integer :number, null: false
      t.date :due_date, null: false
      t.decimal :amount, precision: 12, scale: 2, null: false
      t.date :paid_at
      t.references :paid_by, foreign_key: { to_table: :users }
      t.timestamps
      t.index %i[b2b_order_id number], unique: true
      t.index :paid_at
    end

    create_table :commission_rates, if_not_exists: true do |t|
      t.date :month, null: false
      t.references :beneficiary, polymorphic: true, null: false
      t.decimal :percent, precision: 5, scale: 2, null: false
      t.timestamps
      t.index %i[month beneficiary_type beneficiary_id], unique: true, name: 'index_commission_rates_on_month_and_beneficiary'
    end
  end
end
