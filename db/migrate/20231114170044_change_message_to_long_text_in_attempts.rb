class ChangeMessageToLongTextInAttempts < ActiveRecord::Migration[7.0]
  def change
    change_column :attempts, :message, :longtext
  end
end
