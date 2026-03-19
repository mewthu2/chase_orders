class AddIncompletePaidToOrderPdvStatus < ActiveRecord::Migration[7.2]
  def up
    execute <<~SQL
      ALTER TABLE order_pdvs
        MODIFY COLUMN status VARCHAR(20) NOT NULL DEFAULT 'pending';
    SQL
  end

  def down
    execute <<~SQL
      ALTER TABLE order_pdvs
        MODIFY COLUMN status VARCHAR(20) NOT NULL DEFAULT 'pending';
    SQL
  end
end
