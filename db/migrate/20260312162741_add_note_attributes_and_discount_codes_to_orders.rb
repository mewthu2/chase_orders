class AddNoteAttributesAndDiscountCodesToOrders < ActiveRecord::Migration[7.2]
  def change
    add_column :orders, :note_attributes, :json
    add_column :orders, :discount_codes, :json
  end
end