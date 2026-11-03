# Permissão por ação (V ver, C criar, E editar, A aprovar, X executar, D excluir, P exportar)
# e lojas por perfil. Quem já tinha uma tela continua com todas as ações dela; as telas novas
# (Cadastro de Clientes, Abastecimento Lojas e Transferência B2B → B2C) nascem
# liberadas para quem já as usava através de outra permissão. Em Chamados, abrir e responder
# continuam valendo para todos (Screen base_actions); excluir segue só para quem receber.
class AddActionsAndLocationsToPermissions < ActiveRecord::Migration[7.2]
  # Cópia congelada de Screen::DEFINITIONS[*][:acts] no momento desta migração.
  ACTS = {
    'tickets' => 'VCED', 'whatsapp_attend' => 'VCE', 'whatsapp_manage' => 'VCEXD',
    'stock_corrections' => 'VCEXD', 'stock_withdrawals' => 'VCEXD', 'internal_transfers' => 'VCEAXD',
    'cashback_unifications' => 'VCX', 'dashboard_correios' => 'VEXDP', 'stock_reservations_b2c' => 'VX',
    'customers' => 'V', 'orders' => 'VP', 'discounts' => 'VEX', 'dashboard_correios_b2b' => 'VAEXDP',
    'stock_reservations_b2b' => 'VX', 'planner_orders' => 'VCEXP', 'store_supply' => 'VCEXDP',
    'transfer_locations' => 'VCED', 'b2b_transfers' => 'VCEXDP', 'clients' => 'VCED',
    'b2b_orders' => 'VCEXDP', 'b2b_catalogs' => 'VCEXP', 'users_management' => 'VCED',
    'marketing_campaigns' => 'VCEXD', 'marketing_tasks' => 'VEXP', 'fiscal_notes' => 'VCEXP',
    'companies' => 'VCEXD', 'carriers' => 'VCED', 'logs' => 'V'
  }.freeze

  # Telas novas que antes eram cobertas pela permissão de Pedidos B2B.
  FROM_B2B_ORDERS = %w[store_supply b2b_transfers clients].freeze

  def up
    add_column :screen_permissions, :actions, :string, null: false, default: ''
    add_column :profiles, :allowed_locations, :json

    now = Time.current
    ACTS.each do |key, letters|
      execute(<<~SQL)
        UPDATE screen_permissions SET actions = #{quote(letters)} WHERE screen_key = #{quote(key)}
      SQL
    end

    rows = []
    select_values("SELECT profile_id FROM screen_permissions WHERE screen_key = 'b2b_orders'").uniq.each do |profile_id|
      FROM_B2B_ORDERS.each { |key| rows << [profile_id, key, ACTS[key]] }
    end

    rows.each do |profile_id, key, letters|
      execute(<<~SQL)
        INSERT IGNORE INTO screen_permissions (profile_id, screen_key, actions, created_at, updated_at)
        VALUES (#{profile_id.to_i}, #{quote(key)}, #{quote(letters)}, #{quote(now)}, #{quote(now)})
      SQL
    end
  end

  def down
    execute("DELETE FROM screen_permissions WHERE screen_key IN ('store_supply', 'b2b_transfers', 'clients')")
    remove_column :profiles, :allowed_locations
    remove_column :screen_permissions, :actions
  end

  private

  def quote(value)
    connection.quote(value)
  end
end
