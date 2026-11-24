# Verificação em 2 etapas por e-mail (TwoFactorLogin): o código de 6 dígitos fica só como HMAC,
# com a hora do envio e as tentativas erradas. Só colunas novas: segura para rodar a qualquer momento.
class AddLoginCodeToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :login_code_digest, :string unless column_exists?(:users, :login_code_digest)
    add_column :users, :login_code_sent_at, :datetime unless column_exists?(:users, :login_code_sent_at)
    add_column :users, :login_code_attempts, :integer, default: 0, null: false unless column_exists?(:users, :login_code_attempts)
  end
end
