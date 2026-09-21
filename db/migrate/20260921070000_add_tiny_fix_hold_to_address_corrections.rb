class AddTinyFixHoldToAddressCorrections < ActiveRecord::Migration[7.2]
  # Quando a emissão da nota é recusada pelo Tiny por endereço e o Honey já tem a correção, o pedido
  # fica "aguardando correção da nota no Tiny" (o Honey não consegue alterar a nota pela API).
  def change
    add_column :address_corrections, :awaiting_tiny_fix_at, :datetime
    add_column :address_corrections, :awaiting_tiny_fix_message, :text
    add_column :address_corrections, :tiny_fixed_at, :datetime
    add_index :address_corrections, :awaiting_tiny_fix_at
  end
end
