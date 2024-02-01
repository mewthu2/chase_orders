class AddIdNotaTiny2ToAttempts < ActiveRecord::Migration[7.0]
  def change
    add_column :attempts, :id_nota_tiny2, :integer, after: :id_nota_fiscal
  end
end
