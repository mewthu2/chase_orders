# Ponto exige login no Honey: cada funcionário fica ligado a um usuário (no máximo um funcionário por usuário).
class AddUserToHrEmployees < ActiveRecord::Migration[8.1]
  def change
    return if column_exists?(:hr_employees, :user_id)

    add_reference :hr_employees, :user, foreign_key: true, index: { unique: true }
  end
end
