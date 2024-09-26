class AddIdNotaTiny2ToAttempts < ActiveRecord::Migration[7.0]
  def up
    add_column :attempts, :id_nota_tiny2, :integer
  end

  def down
    remove_column :attempts, :id_nota_tiny2
  end
end
