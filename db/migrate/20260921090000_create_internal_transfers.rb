class CreateInternalTransfers < ActiveRecord::Migration[7.2]
  # Transferência interna entre lojas (locations do Shopify): um pedido, com uma loja de
  # destino, pode reunir itens de várias lojas de origem. Cada origem vira uma "remessa"
  # (shipment) com o próprio andamento e o próprio código de rastreio.
  def change
    create_table :internal_transfers do |t|
      t.references :destination_location, null: false, foreign_key: { to_table: :locations }
      t.references :requested_by, null: false, foreign_key: { to_table: :users }
      t.text :notes

      t.timestamps
    end

    create_table :internal_transfer_shipments do |t|
      t.references :internal_transfer, null: false, foreign_key: true
      t.references :origin_location, null: false, foreign_key: { to_table: :locations }
      t.integer :status, null: false, default: 0 # aberto, reservado, enviado, recebido, cancelado
      t.string :tracking_code
      t.references :reserved_by, foreign_key: { to_table: :users }, null: true
      t.references :sent_by, foreign_key: { to_table: :users }, null: true
      t.references :received_by, foreign_key: { to_table: :users }, null: true
      t.references :cancelled_by, foreign_key: { to_table: :users }, null: true
      t.datetime :reserved_at
      t.datetime :sent_at
      t.datetime :received_at
      t.datetime :cancelled_at

      t.timestamps
    end
    add_index :internal_transfer_shipments, [:internal_transfer_id, :origin_location_id],
              unique: true, name: 'idx_transfer_shipments_unique_origin'

    create_table :internal_transfer_items do |t|
      t.references :internal_transfer_shipment, null: false, foreign_key: true
      t.references :product, null: false, foreign_key: true
      t.integer :quantity, null: false
      t.integer :status, null: false, default: 0 # pending, reserved, received, failed, cancelled
      t.integer :available_before
      t.text :error_message
      t.string :reserve_adjustment_id
      t.string :receive_adjustment_id
      t.datetime :reserved_at
      t.datetime :received_at
      t.datetime :cancelled_at

      t.timestamps
    end
    add_index :internal_transfer_items, [:internal_transfer_shipment_id, :product_id],
              unique: true, name: 'idx_transfer_items_unique_product'

    # Linha do tempo do pedido: quem fez o quê, em qual remessa.
    create_table :internal_transfer_events do |t|
      t.references :internal_transfer, null: false, foreign_key: true
      t.references :internal_transfer_shipment, foreign_key: true, null: true
      t.references :user, foreign_key: true, null: true
      t.string :action, null: false
      t.text :message

      t.timestamps
    end
  end
end
