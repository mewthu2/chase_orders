class Screen
  DEFINITIONS = {
    users_management:      'Gerenciar Usuários',
    orders:                 'Pedidos',
    customers:              'Clientes',
    discounts:              'Descontos',
    logs:                   'Logs',
    dashboard_correios:     'Painel de Correios B2C',
    dashboard_correios_b2b: 'Painel de Correios B2B',
    marketing_campaigns:    'Campanhas de Marketing',
    marketing_tasks:        'Tarefas de Marketing',
    b2b_orders:             'Pedidos B2B',
    transfer_locations:     'Locais de Transferência',
    carriers:               'Transportadoras',
    planner_orders:         'Planejador',
    stock_corrections:      'Controle de Estoque'
  }.freeze

  # Agrupamento espelhando o menu lateral — usado na tela de Perfis pra
  # organizar as permissões do mesmo jeito que o usuário vê o menu.
  GROUPS = {
    'Pedidos B2B'  => %i[b2b_orders transfer_locations carriers],
    'CRM'          => %i[orders customers],
    'Correios B2C' => %i[dashboard_correios],
    'Correios B2B' => %i[dashboard_correios_b2b],
    'Planejador'   => %i[planner_orders],
    'Produtos'     => %i[stock_corrections],
    'Outros'       => %i[discounts logs marketing_campaigns marketing_tasks users_management]
  }.freeze

  def self.keys = DEFINITIONS.keys.map(&:to_s)
  def self.options_for_select = DEFINITIONS.map { |k, v| [v, k.to_s] }
  def self.label(key) = DEFINITIONS[key.to_sym]
  def self.grouped = GROUPS.transform_values { |keys| keys.map { |k| [DEFINITIONS[k], k.to_s] } }
end
