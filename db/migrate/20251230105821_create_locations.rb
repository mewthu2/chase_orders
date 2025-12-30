class CreateLocations < ActiveRecord::Migration[7.2]
  def up
    create_table :locations do |t|
      t.string :slug, null: false
      t.string :name, null: false
      t.decimal :kpi_ratio, precision: 5, scale: 2
      t.datetime :kpi_updated_at
      t.timestamps
    end

    add_index :locations, :slug, unique: true
    add_index :locations, :kpi_ratio
  end

  def down
    drop_table :locations
  end
end
