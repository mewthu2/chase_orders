# Financeiro › Pedidos de Atacado ganhou Exportar (planilha e XML das notas): o perfil Financeiro recebe a letra P.
# Idempotente: pode rodar a qualquer momento.
class FinanceOrdersExportPermission < ActiveRecord::Migration[8.1]
  def up
    profile_id = select_value("SELECT id FROM profiles WHERE name = 'Financeiro' LIMIT 1")
    return unless profile_id

    execute <<~SQL
      UPDATE screen_permissions SET actions = CONCAT(actions, 'P'), updated_at = NOW()
      WHERE profile_id = #{profile_id.to_i} AND screen_key = 'finance_orders' AND actions LIKE '%V%' AND actions NOT LIKE '%P%'
    SQL
  end

  def down; end
end
