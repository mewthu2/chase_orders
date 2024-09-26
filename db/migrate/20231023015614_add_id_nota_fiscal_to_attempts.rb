class AddIdNotaFiscalToAttempts < ActiveRecord::Migration[7.0]
  def up
    add_column :attempts, :id_nota_fiscal, :integer
  end

  def down
    remove_column :attempts, :id_nota_fiscal
  end
end
