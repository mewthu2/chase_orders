# Priorização de reserva de estoque: o degrau de cada origem de reserva (pedidos B2C, atacado, abastecimento e
# transferências). Sem linha salva, vale o padrão de StockReservationPriority::SOURCES.
# stock_reservations.source guarda a origem de cada reserva; as do Log03 que já existem são de pedidos B2C.
# Só tabela e coluna novas: segura para rodar a qualquer momento.
class CreateStockReservationPriorities < ActiveRecord::Migration[8.0]
  def up
    unless table_exists?(:stock_reservation_priorities)
      create_table :stock_reservation_priorities do |t|
        t.string :source, null: false
        t.integer :level, null: false, default: 1
        t.timestamps
        t.index :source, unique: true
      end
    end
    add_column :stock_reservations, :source, :string unless column_exists?(:stock_reservations, :source)
    execute "UPDATE stock_reservations SET source = 'b2c_orders' WHERE account = 1 AND source IS NULL AND tiny_order_id NOT LIKE 'H%'"
  end

  def down
    remove_column :stock_reservations, :source if column_exists?(:stock_reservations, :source)
    drop_table :stock_reservation_priorities if table_exists?(:stock_reservation_priorities)
  end
end
