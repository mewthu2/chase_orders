class AddFontScaleToUsers < ActiveRecord::Migration[7.2]
  def change
    add_column :users, :font_scale, :integer, default: 100, null: false
  end
end
