# Ordem e visibilidade das colunas de cada tabela (HoneyTable), por usuário.
class CreateTableColumnPreferences < ActiveRecord::Migration[8.1]
  def change
    return if table_exists?(:table_column_preferences)

    create_table :table_column_preferences do |t|
      t.references :user, null: false, foreign_key: true
      t.string :table_key, null: false, limit: 191
      t.json :columns, null: false
      t.timestamps
    end
    add_index :table_column_preferences, %i[user_id table_key], unique: true
  end
end
