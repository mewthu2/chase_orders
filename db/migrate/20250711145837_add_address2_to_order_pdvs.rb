class AddAddress2ToOrderPdvs < ActiveRecord::Migration[7.2]
  def change
    add_column :order_pdvs, :address2, :string
  end
end
