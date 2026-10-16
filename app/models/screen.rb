class Screen
  DEFINITIONS = {
    whatsapp_attend: 'Atendimento WhatsApp — Conversas',
    whatsapp_manage: 'Atendimento WhatsApp — Administrar conexões',
    users_management:      'Gerenciar Usuários',
    orders:                 'Pedidos',
    customers:              'Clientes',
    discounts:              'Descontos',
    cashback_unifications:  'Cupons de Cashback',
    logs:                   'Logs',
    dashboard_correios:     'Painel de Correios B2C',
    dashboard_correios_b2b: 'Painel de Correios B2B',
    stock_reservations_b2c: 'Reservas de Estoque B2C',
    stock_reservations_b2b: 'Reservas de Estoque B2B',
    marketing_campaigns:    'Campanhas de Marketing',
    marketing_tasks:        'Tarefas de Marketing',
    b2b_orders:             'Pedidos B2B',
    transfer_locations:     'Locais de Transferência',
    carriers:               'Transportadoras',
    companies:              'Empresas',
    fiscal_notes:           'Notas Fiscais',
    b2b_catalogs:           'Catálogos B2B',
    planner_orders:         'Planejador',
    stock_corrections:      'Controle de Estoque',
    stock_withdrawals:      'Retirada de Estoque',
    internal_transfers:     'Transferência Interna'
  }.freeze

  # Agrupamento espelhando o menu lateral — usado na tela de Perfis pra
  # organizar as permissões do mesmo jeito que o usuário vê o menu.
  GROUPS = {
    'Atendimento WhatsApp' => %i[whatsapp_attend whatsapp_manage],
    'Pedidos B2B'  => %i[b2b_orders carriers companies fiscal_notes b2b_catalogs],
    'CRM'          => %i[orders customers cashback_unifications],
    'Correios B2C' => %i[dashboard_correios stock_reservations_b2c],
    'Correios B2B' => %i[dashboard_correios_b2b stock_reservations_b2b],
    'Planejador'   => %i[planner_orders],
    'Produtos'     => %i[stock_corrections stock_withdrawals internal_transfers transfer_locations],
    'Outros'       => %i[discounts logs marketing_campaigns marketing_tasks users_management]
  }.freeze

  def self.keys = DEFINITIONS.keys.map(&:to_s)
  def self.options_for_select = DEFINITIONS.map { |k, v| [v, k.to_s] }
  def self.label(key) = DEFINITIONS[key.to_sym]
  def self.grouped = GROUPS.transform_values { |keys| keys.map { |k| [DEFINITIONS[k], k.to_s] } }
end
