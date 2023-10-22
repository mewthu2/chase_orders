class CreateAttempt < ActiveRecord::Migration[7.0]
  def change
    create_table :attempts do |t|
      t.bigint :kinds
      t.bigint :status
      t.text :requisition
      t.text :params
      t.string :error
      t.string :status_code
      t.string :message
      t.string :exception
      t.string :classification
      t.string :cause
      t.string :url
      t.string :user
      t.integer :tiny_order_id
      t.timestamps
    end
  end
end
