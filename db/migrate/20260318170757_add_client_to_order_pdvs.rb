class AddClientToOrderPdvs < ActiveRecord::Migration[7.2]
  def change
    add_reference :order_pdvs, :client, null: true, foreign_key: true
  end
end