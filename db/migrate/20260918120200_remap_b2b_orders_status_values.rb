class RemapB2bOrdersStatusValues < ActiveRecord::Migration[7.2]
  def up
    execute <<~SQL.squish
      UPDATE b2b_orders SET status = CASE status
        WHEN 0 THEN 0
        WHEN 1 THEN 0
        WHEN 2 THEN 0
        WHEN 3 THEN 7
        ELSE status
      END
    SQL
  end

  def down
    execute <<~SQL.squish
      UPDATE b2b_orders SET status = CASE status
        WHEN 7 THEN 3
        ELSE 0
      END
    SQL
  end
end
