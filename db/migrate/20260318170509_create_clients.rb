class CreateClients < ActiveRecord::Migration[7.2]
  def change
    create_table :clients do |t|
      t.string :responsible_name,        null: false
      t.string :business_name
      t.string :registration
      t.string :state_registration
      t.string :municipal_registration
      t.string :street
      t.string :neighbourhood
      t.string :number
      t.string :city
      t.string :state
      t.string :zip
      t.string :email
      t.string :phone

      t.timestamps
    end

    add_index :clients, :registration
    add_index :clients, :responsible_name
  end
end