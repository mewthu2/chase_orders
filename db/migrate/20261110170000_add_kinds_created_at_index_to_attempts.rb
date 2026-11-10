# A tabela attempts passa de 2 milhões de linhas: contar as tentativas de hoje por tipo
# (telas do Log03/Log02) varria tudo. Índice criado online, sem travar a tabela.
class AddKindsCreatedAtIndexToAttempts < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  def change
    add_index :attempts, %i[kinds status created_at], algorithm: :inplace, if_not_exists: true
  end
end
