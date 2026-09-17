class CreateAddressCorrections < ActiveRecord::Migration[7.2]
  def change
    create_table :address_corrections do |t|
      t.string :tiny_order_id, null: false
      t.string :endereco
      t.string :numero
      t.string :complemento
      t.string :bairro
      t.string :cep
      t.string :cidade
      t.string :uf

      t.timestamps
    end

    add_index :address_corrections, :tiny_order_id, unique: true
  end
end
