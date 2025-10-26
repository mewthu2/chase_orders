class CreateApiUsers < ActiveRecord::Migration[7.2]
  def change
    create_table :api_users do |t|
      t.string :email
      t.string :password_digest

      t.timestamps
    end
  end
end
