class AddReservationStatusToOrderPdvs < ActiveRecord::Migration[7.2]
  def change
    add_column :order_pdvs, :reservation_status, :string
  end
end
