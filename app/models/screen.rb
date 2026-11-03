# Telas com permissão própria. Cada uma pertence a uma área do negócio (a mesma do menu)
# e oferece um conjunto de ações; o perfil libera, por tela, só as ações que quiser.
class Screen
  # Ações que um perfil pode receber numa tela. A letra é o que fica gravado em
  # screen_permissions.actions.
  ACTIONS = {
    'V' => { label: 'Ver',      icon: 'fas fa-eye',          help: 'Abrir a tela e consultar as informações.' },
    'C' => { label: 'Criar',    icon: 'fas fa-plus',         help: 'Cadastrar algo novo (pedido, cliente, conferência...).' },
    'E' => { label: 'Editar',   icon: 'fas fa-pen',          help: 'Alterar o que já foi cadastrado.' },
    'A' => { label: 'Aprovar',  icon: 'fas fa-circle-check', help: 'Liberar ou confirmar o que outra pessoa pediu.' },
    'X' => { label: 'Executar', icon: 'fas fa-bolt',         help: 'Rodar rotinas e mandar dados para o Tiny, o Correios, a SEFAZ ou o Shopify.' },
    'D' => { label: 'Excluir',  icon: 'fas fa-trash',        help: 'Apagar, cancelar ou reverter.' },
    'P' => { label: 'Exportar', icon: 'fas fa-file-export',  help: 'Baixar planilha, PDF ou XML.' }
  }.freeze
  ACTION_LETTERS = ACTIONS.keys.freeze

  AREAS = {
    'geral'     => { title: 'Geral',       icon: 'fas fa-compass',      color: '#3aa3ea', desc: 'O que todo mundo usa: chamados e atendimento.' },
    'loja'      => { title: 'Loja Física', icon: 'fas fa-store',        color: '#f0883e', desc: 'Estoque e cupons das lojas.' },
    'ecommerce' => { title: 'Ecommerce',   icon: 'fas fa-bag-shopping', color: '#b58cff', desc: 'Loja online: envios, clientes e cupons.' },
    'logistica' => { title: 'Logística',   icon: 'fas fa-truck-fast',   color: '#3fb950', desc: 'Envios do atacado, planejador e abastecimento.' },
    'atacado'   => { title: 'Atacado',     icon: 'fas fa-handshake',    color: '#e3b341', desc: 'Lojistas: clientes, pedidos e catálogos.' },
    'adm'       => { title: 'Adm',         icon: 'fas fa-gear',         color: '#8b949e', desc: 'Acessos, equipe, marketing e cadastros fiscais.' }
  }.freeze

  # acts: ações que existem na tela; loc: a tela trabalha com loja (o filtro por loja vale nela);
  # base: ações que todo usuário logado já tem na tela (o perfil escolhe só as outras).
  DEFINITIONS = {
    tickets:                { label: 'Chamados',                              area: 'geral',     acts: 'VCED', base: 'VCE' },
    whatsapp_attend:        { label: 'WhatsApp · Conversas',                  area: 'geral',     acts: 'VCE' },
    whatsapp_manage:        { label: 'WhatsApp · Números conectados',         area: 'geral',     acts: 'VCEXD' },
    stock_corrections:      { label: 'Controle de Estoque',                   area: 'loja',      acts: 'VCEXD', loc: true },
    stock_withdrawals:      { label: 'Retirada de Estoque',                   area: 'loja',      acts: 'VCEXD', loc: true },
    internal_transfers:     { label: 'Transferência de Estoque',              area: 'loja',      acts: 'VCEAXD', loc: true },
    cashback_unifications:  { label: 'Cupons de cashback',                    area: 'loja',      acts: 'VCX' },
    dashboard_correios:     { label: 'Log03 · Etapas, funil e consultas',     area: 'ecommerce', acts: 'VEXDP' },
    stock_reservations_b2c: { label: 'Log03 · Reservas de Estoque',           area: 'ecommerce', acts: 'VX' },
    customers:              { label: 'Clientes',                              area: 'ecommerce', acts: 'V' },
    orders:                 { label: 'Pedidos Shopify e Uso de Cupons',       area: 'ecommerce', acts: 'VP' },
    discounts:              { label: 'Descontos',                             area: 'ecommerce', acts: 'VEX' },
    dashboard_correios_b2b: { label: 'Log02 · Etapas e consultas',            area: 'logistica', acts: 'VAEXDP' },
    stock_reservations_b2b: { label: 'Log02 · Reservas de Estoque',           area: 'logistica', acts: 'VX' },
    planner_orders:         { label: 'Planejador',                            area: 'logistica', acts: 'VCEXP' },
    store_supply:           { label: 'Abastecimento Lojas',                   area: 'logistica', acts: 'VCEXDP', loc: true },
    transfer_locations:     { label: 'Locais de Transferência',               area: 'logistica', acts: 'VCED' },
    b2b_transfers:          { label: 'Transferência B2B → B2C',               area: 'logistica', acts: 'VCEXDP' },
    clients:                { label: 'Cadastro de Clientes',                  area: 'atacado',   acts: 'VCED' },
    b2b_orders:             { label: 'Pedidos de Atacado',                    area: 'atacado',   acts: 'VCEXDP' },
    b2b_catalogs:           { label: 'Catálogos',                             area: 'atacado',   acts: 'VCEXP' },
    users_management:       { label: 'Gerenciar Usuários',                    area: 'adm',       acts: 'VCED' },
    marketing_campaigns:    { label: 'Campanhas de Marketing',                area: 'adm',       acts: 'VCEXD' },
    marketing_tasks:        { label: 'Tarefas de Marketing',                  area: 'adm',       acts: 'VEXP' },
    fiscal_notes:           { label: 'Notas Fiscais',                         area: 'adm',       acts: 'VCEXP' },
    companies:              { label: 'Empresas e Naturezas de Operação',      area: 'adm',       acts: 'VCEXD' },
    carriers:               { label: 'Transportadoras',                       area: 'adm',       acts: 'VCED' },
    logs:                   { label: 'Logs',                                  area: 'adm',       acts: 'V' }
  }.freeze

  def self.keys = DEFINITIONS.keys.map(&:to_s)
  def self.definition(key) = DEFINITIONS[key.to_s.to_sym]
  def self.label(key) = definition(key)&.dig(:label)
  def self.options_for_select = DEFINITIONS.map { |k, v| [v[:label], k.to_s] }
  def self.base_actions(key) = definition(key)&.dig(:base).to_s
  def self.base?(key) = base_actions(key).present?
  def self.location?(key) = definition(key)&.dig(:loc) == true

  # Ações que existem na tela, em letras ("VCED").
  def self.acts(key)
    definition(key)&.dig(:acts).to_s
  end

  # Mantém só as letras que a tela oferece, na ordem de ACTIONS, e sempre com V:
  # quem pode criar ou executar numa tela precisa conseguir abri-la.
  def self.normalize_actions(key, letters)
    allowed = acts(key)
    chosen = letters.to_s.upcase.chars & allowed.chars
    return '' if chosen.empty?

    (ACTION_LETTERS & (chosen | ['V'])).join
  end

  # { 'geral' => [['tickets', {...}], ...], ... } na ordem das áreas.
  def self.by_area
    AREAS.keys.index_with { |area| DEFINITIONS.select { |_, d| d[:area] == area }.map { |k, d| [k.to_s, d] } }
  end
end
