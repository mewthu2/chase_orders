class ChangeMessageToLongTextInAttempts < ActiveRecord::Migration[7.0]
  def up
    change_column :attempts, :message, :text
  end

  def down
    change_column :attempts, :message, :string
  end
end
