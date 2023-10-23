class AddIdNotaFiscalToAttempts < ActiveRecord::Migration[7.0]
  def change
    add_column :attempts, :id_nota_fiscal, :integer, after: :order_correios_id
  end
end
