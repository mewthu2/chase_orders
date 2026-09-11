class AddKindsStatusOrderCorreiosIdIndexToAttempts < ActiveRecord::Migration[7.2]
  def change
    add_index :attempts, [:kinds, :status, :order_correios_id],
              name: 'index_attempts_on_kinds_status_order_correios_id'
  end
end
