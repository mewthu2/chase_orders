class CreateCarriers < ActiveRecord::Migration[7.2]
  def change
    create_table :carriers do |t|
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
      t.string :phone
      t.string :email
      t.boolean :active, null: false, default: true
      t.string :tiny_contact_id
      t.datetime :transmitted_at
      t.text :tiny_error
      t.timestamps
    end
  end
end
