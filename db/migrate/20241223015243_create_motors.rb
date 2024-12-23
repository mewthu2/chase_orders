class CreateMotors < ActiveRecord::Migration[7.2]
  def change
    create_table :motors do |t|
      t.string :job_name
      t.datetime :start_time
      t.datetime :end_time
      t.integer :running_time
      t.text :link
      t.timestamps
    end
  end
end