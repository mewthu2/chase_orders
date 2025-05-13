class AddStepToMotors < ActiveRecord::Migration[7.0]
  def change
    add_column :motors, :step, :string, after: :link
  end
end