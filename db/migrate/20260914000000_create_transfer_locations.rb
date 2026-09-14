class CreateTransferLocations < ActiveRecord::Migration[7.2]
  def change
    create_table :transfer_locations do |t|
      t.string :name, null: false
      t.string :registration, null: false
      t.string :state_registration
      t.string :street, null: false
      t.string :number, null: false
      t.string :complement
      t.string :neighbourhood, null: false
      t.string :city, null: false
      t.string :state, null: false
      t.string :zip, null: false
      t.boolean :active, null: false, default: true
      t.timestamps
    end
  end
end
