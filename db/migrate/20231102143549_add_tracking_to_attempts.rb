class AddTrackingToAttempts < ActiveRecord::Migration[7.0]
  def change
    add_column :attempts, :tracking, :string, after: :id_nota_fiscal
  end
end
