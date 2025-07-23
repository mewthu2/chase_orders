class AddIndexToAttemptsKinds < ActiveRecord::Migration[7.2]
  def change
    add_index :attempts, :kinds
  end
end
