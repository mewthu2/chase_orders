class AddIsTransportadoraToAttempts < ActiveRecord::Migration[7.2]
  def change
    add_column :attempts, :is_transportadora, :boolean, default: false
  end
end
