# Atacado:
# - b2b_freight_rates: tabela de frete por valor do pedido (faixas de R$ 5 mil, de R$ 300,00 a R$ 1.000,00);
# - b2b_orders.pickup: forma de envio "Retirada" (o cliente busca, sem frete);
# - perfil "Atacado" com as telas do atacado.
# Segura para rodar a qualquer momento: só semeia o que ainda não existe.
class CreateB2bFreightRates < ActiveRecord::Migration[8.0]
  RATES = [
    [0, 5_000, 300.00], [5_000.01, 10_000, 336.84], [10_000.01, 15_000, 373.68], [15_000.01, 20_000, 410.53],
    [20_000.01, 25_000, 447.37], [25_000.01, 30_000, 484.21], [30_000.01, 35_000, 521.05], [35_000.01, 40_000, 557.89],
    [40_000.01, 45_000, 594.74], [45_000.01, 50_000, 631.58], [50_000.01, 55_000, 668.42], [55_000.01, 60_000, 705.26],
    [60_000.01, 65_000, 742.11], [65_000.01, 70_000, 778.95], [70_000.01, 75_000, 815.79], [75_000.01, 80_000, 852.63],
    [80_000.01, 85_000, 889.47], [85_000.01, 90_000, 926.32], [90_000.01, 95_000, 963.16], [95_000.01, 100_000, 1000.00]
  ].freeze

  WHOLESALE_PROFILE = 'Atacado'.freeze
  WHOLESALE_SCREENS = { 'clients' => 'VCED', 'b2b_orders' => 'VCEXDP', 'b2b_catalogs' => 'VCEXP', 'carriers' => 'VCE' }.freeze

  def up
    create_table :b2b_freight_rates, if_not_exists: true do |t|
      t.decimal :min_value, precision: 12, scale: 2, null: false, default: 0
      t.decimal :max_value, precision: 12, scale: 2, null: false
      t.decimal :price, precision: 12, scale: 2, null: false, default: 0
      t.timestamps
    end
    add_column :b2b_orders, :pickup, :boolean, default: false, null: false, if_not_exists: true

    now = connection.quote(Time.current)
    if select_value('SELECT COUNT(*) FROM b2b_freight_rates').to_i.zero?
      values = RATES.map { |min, max, price| "(#{min}, #{max}, #{price}, #{now}, #{now})" }.join(', ')
      execute "INSERT INTO b2b_freight_rates (min_value, max_value, price, created_at, updated_at) VALUES #{values}"
    end

    profile_id = select_value("SELECT id FROM profiles WHERE name = #{connection.quote(WHOLESALE_PROFILE)}")
    unless profile_id
      execute "INSERT INTO profiles (name, description, active, created_at, updated_at) VALUES " \
              "(#{connection.quote(WHOLESALE_PROFILE)}, #{connection.quote('Equipe do atacado: clientes, pedidos, catálogos e transportadoras.')}, TRUE, #{now}, #{now})"
      profile_id = select_value("SELECT id FROM profiles WHERE name = #{connection.quote(WHOLESALE_PROFILE)}")
      WHOLESALE_SCREENS.each do |key, actions|
        execute "INSERT INTO screen_permissions (profile_id, screen_key, actions, created_at, updated_at) VALUES " \
                "(#{profile_id}, #{connection.quote(key)}, #{connection.quote(actions)}, #{now}, #{now})"
      end
    end
  end

  def down
    remove_column :b2b_orders, :pickup, if_exists: true
    drop_table :b2b_freight_rates, if_exists: true
  end
end
