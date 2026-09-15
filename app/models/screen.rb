class Screen
  DEFINITIONS = {
    users_management:   'Gerenciar Usuários',
    orders:              'Pedidos',
    customers:           'Clientes',
    discounts:           'Descontos',
    logs:                'Logs',
    dashboard_correios:  'Painel de Correios',
    marketing_campaigns: 'Campanhas de Marketing',
    marketing_tasks:     'Tarefas de Marketing',
    b2b_orders:          'Pedidos B2B',
    transfer_locations:  'Locais de Transferência',
    carriers:            'Transportadoras'
  }.freeze

  def self.keys = DEFINITIONS.keys.map(&:to_s)
  def self.options_for_select = DEFINITIONS.map { |k, v| [v, k.to_s] }
  def self.label(key) = DEFINITIONS[key.to_sym]
end
