class AddTrackingToAttempts < ActiveRecord::Migration[7.0]
  def up
    add_column :attempts, :tracking, :string
  end

  def down
    remove_column :attempts, :tracking
  end
end
