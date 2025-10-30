class AllowNullUserIdInMarketingTasks < ActiveRecord::Migration[7.2]
  def change
    change_column_null :marketing_tasks, :user_id, true
  end
end