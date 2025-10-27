class AddTaskTypeAndDueDateToMarketingTasks < ActiveRecord::Migration[7.2]
  def change
    add_column :marketing_tasks, :task_type, :integer, default: 0, null: false
    add_column :marketing_tasks, :due_date, :date
    
    add_index :marketing_tasks, :task_type
    add_index :marketing_tasks, :due_date
    add_index :marketing_tasks, [:user_id, :task_type]
  end
end
