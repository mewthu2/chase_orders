# Menu do painel organizado por área do negócio (Screen::AREAS). A mesma estrutura alimenta
# a barra lateral, a busca rápida (Ctrl + K), o mapa do sistema e a ajuda de cada tela.
#
# Cada item: id (casa com config/honey/help.json), label, icon, desc, path (lambda que recebe
# a view), perm (chave de Screen; nil = qualquer usuário logado), cond (:admin ou
# :sectors_non_admin), active (lambda que recebe a view e diz se a tela atual é este item),
# step (número da etapa nos fluxos do Correios), aka (nome antigo), badge (:waiting_me, :catalogs).
module Navigation
  module_function

  def ctrl(*names) = ->(v) { names.include?(v.controller_path) }
  def page(controller, *actions) = ->(v) { v.controller_path == controller && actions.include?(v.action_name) }
  def kind(value) = ->(v) { v.controller_path == 'b2b_orders' && v.params[:order_kind] == value }
  def channel(value) = ->(v) { v.controller_path == 'attempts' && v.params[:channel] == value }
  def home(scope) = ->(v) { v.controller_path == 'home' && (v.params[:scope].presence || 'mine') == scope }

  def menu
    @menu ||= [
      area('geral', [
        group('chamados', 'Chamados', 'fas fa-ticket-alt', 'Pedidos de ajuda entre setores. Comece por aqui.', badge: :waiting_me, children: [
          link('inicio', 'Meus chamados', 'fas fa-inbox', 'O que você abriu, resolve ou acompanha.', path: ->(v) { v.root_path }, active: home('mine'), badge: :waiting_me),
          link('abrir-chamado', 'Abrir chamado', 'fas fa-plus-circle', 'Peça ajuda a outra área. Ela recebe um e-mail na hora.',
               path: ->(v) { v.new_ticket_path }, perm: 'tickets', act: 'C', active: page('tickets', 'new', 'create')),
          link('chamados-setores', 'Chamados dos meus setores', 'fas fa-building', 'Todos os chamados dos setores liberados para você.',
               path: ->(v) { v.root_path(scope: 'sectors', status: 'all') }, cond: :sectors_non_admin, active: home('sectors')),
          link('chamados-todos', 'Todos os chamados', 'fas fa-list-ul', 'Todos os chamados de todos os setores.',
               path: ->(v) { v.root_path(scope: 'all', status: 'all') }, cond: :admin, active: home('all'))
        ]),
        group('whatsapp', 'Atendimento WhatsApp', 'fab fa-whatsapp', 'Conversas com clientes pelo WhatsApp da empresa.', children: [
          link('wa-conversas', 'Conversas', 'fas fa-comments', 'Responda clientes em equipe, numa caixa única.',
               path: ->(v) { v.whatsapp_conversations_path }, perm: 'whatsapp_attend', active: ctrl('whatsapp/conversations')),
          link('wa-automacoes', 'Automações e agente', 'fas fa-robot', 'Ensine o agente de IA a responder os clientes de cada número.',
               path: ->(v) { v.whatsapp_automations_path }, perm: 'whatsapp_manage', active: ctrl('whatsapp/automations')),
          link('wa-numeros', 'Números conectados', 'fas fa-mobile-alt', 'Conecte números pelo QR e escolha quem atende.',
               path: ->(v) { v.whatsapp_connections_path }, perm: 'whatsapp_manage', active: ctrl('whatsapp/connections'))
        ])
      ]),

      area('loja', [
        link('loja-controle', 'Controle de Estoque', 'fas fa-warehouse', 'Conte o estoque de uma loja e corrija o Shopify.',
             path: ->(v) { v.stock_corrections_path }, perm: 'stock_corrections', active: ctrl('stock_corrections')),
        link('loja-retirada', 'Retirada de Estoque', 'fas fa-dolly-flatbed', 'Dê baixa por perda, dano ou marketing, direto no Shopify.',
             path: ->(v) { v.stock_withdrawals_path }, perm: 'stock_withdrawals', active: ctrl('stock_withdrawals')),
        link('loja-transf', 'Transferência de Estoque', 'fas fa-exchange-alt', 'Peça peças de outra loja, com aprovação e rastreio.',
             path: ->(v) { v.internal_transfers_path }, perm: 'internal_transfers', active: ctrl('internal_transfers')),
        link('config-transf', 'Configurar Transferências', 'fas fa-sliders-h', 'Quem aprova as transferências de estoque.',
             path: ->(v) { v.edit_internal_transfer_config_path }, cond: :admin, active: ctrl('internal_transfer_configs')),
        link('loja-cashback', 'Cupons de cashback', 'fas fa-coins', 'Junte dois cupons MTZ da cliente em um cupom UNF.',
             path: ->(v) { v.cashback_unifications_path }, perm: 'cashback_unifications', active: ctrl('cashback_unifications'))
      ]),

      area('ecommerce', [
        group('log03', 'Log03', 'fas fa-mail-bulk', 'Envios da loja online: da criação ao rastreio (etapas 1 a 4).', aka: 'Correios B2C', children: [
          sub('Visão geral'),
          link('log03-funil', 'Funil de Pedidos', 'fas fa-stream', 'Quantos pedidos estão em cada etapa e quais travaram.',
               path: ->(v) { v.correios_pipeline_dashboard_index_path }, perm: 'dashboard_correios', active: page('dashboard', 'correios_pipeline')),
          link('log03-acomp', 'Acompanhamento', 'fas fa-route', 'Em que etapa está cada pedido.',
               path: ->(v) { v.order_correios_tracking_dashboard_index_path }, perm: 'dashboard_correios', active: page('dashboard', 'order_correios_tracking')),
          sub('Etapas do envio', steps: true),
          link('log03-criacao', 'Criação de Pedidos', 'fas fa-plus-circle', 'Cria no Correios os pedidos "preparando envio" do Tiny.', step: 1,
               path: ->(v) { v.order_correios_create_dashboard_index_path }, perm: 'dashboard_correios', active: page('dashboard', 'order_correios_create')),
          link('log03-notas', 'Emissão de Notas', 'fas fa-file-invoice', 'Pede ao Tiny a nota fiscal dos pedidos criados.', step: 2,
               path: ->(v) { v.invoice_emition_dashboard_index_path }, perm: 'dashboard_correios', active: page('dashboard', 'invoice_emition')),
          link('log03-xml', 'Enviar XML', 'fas fa-file-code', 'Envia ao Correios o arquivo da nota de cada pedido.', step: 3,
               path: ->(v) { v.send_xml_dashboard_index_path }, perm: 'dashboard_correios', active: page('dashboard', 'send_xml')),
          link('log03-rastreio', 'Rastreamento', 'fas fa-shipping-fast', 'Busca o código de rastreio e grava no Tiny.', step: 4,
               path: ->(v) { v.push_tracking_dashboard_index_path }, perm: 'dashboard_correios', active: page('dashboard', 'push_tracking')),
          sub('Consultas e ajustes'),
          link('log03-sem-estoque', 'Produtos Sem Estoque', 'fas fa-box-open', 'O que falta no armazém e os pedidos presos por isso.',
               path: ->(v) { v.order_correios_stock_errors_dashboard_index_path }, perm: 'dashboard_correios', active: page('dashboard', 'order_correios_stock_errors')),
          link('log03-reservas', 'Reservas de Estoque', 'fas fa-lock', 'Quanto de cada produto já está comprometido em pedidos.',
               path: ->(v) { v.b2c_stock_reservations_path }, perm: 'stock_reservations_b2c', active: page('stock_reservations', 'b2c')),
          link('log03-tentativas', 'Tentativas', 'fas fa-list-check', 'Histórico de cada tentativa, com o erro e o "Reprocessar".',
               path: ->(v) { v.attempts_path(channel: 'b2c') }, perm: 'dashboard_correios', active: channel('b2c')),
          link('log03-api', 'API Correios', 'fas fa-cogs', 'Consulte estoque e rastreio direto no Correios.',
               path: ->(v) { v.api_correios_dashboard_index_path }, perm: 'dashboard_correios', active: page('dashboard', 'api_correios')),
          link('log03-sync', 'Sincronização Estoque', 'fas fa-sync-alt', 'Copia o estoque do Correios para o Shopify.',
               path: ->(v) { v.stock_syncs_path }, perm: 'dashboard_correios', active: ctrl('stock_syncs'))
        ]),
        link('eco-clientes', 'Clientes', 'fas fa-users', 'Contato, compras e cupons de cada cliente da loja online.',
             path: ->(v) { v.customers_path }, perm: 'customers', active: ctrl('customers')),
        link('eco-cupons', 'Uso de Cupons', 'fas fa-ticket-alt', 'Veja quais cupons mais venderam no período.',
             path: ->(v) { v.coupon_usage_orders_path }, perm: 'orders', active: page('orders', 'coupon_usage')),
        link('eco-pedidos', 'Pedidos Shopify', 'fas fa-shopping-cart', 'Consulte os pedidos da loja online e exporte para planilha.',
             path: ->(v) { v.orders_path }, perm: 'orders', active: page('orders', 'index', 'show'))
      ]),

      area('logistica', [
        group('log02', 'Log02', 'fas fa-truck', 'Envios do atacado: da aprovação ao rastreio (etapas 1 a 5).', aka: 'Correios B2B', children: [
          sub('Visão geral'),
          link('log02-acomp', 'Acompanhamento', 'fas fa-route', 'Em que etapa está cada pedido do atacado.',
               path: ->(v) { v.order_correios_tracking_b2b_dashboard_index_path }, perm: 'dashboard_correios_b2b', active: page('dashboard', 'order_correios_tracking_b2b')),
          sub('Etapas do envio', steps: true),
          link('log02-aprovar', 'Pedidos p/ Aprovar', 'fas fa-clipboard-check', 'Decida quais pedidos do atacado seguem para o Correios.', step: 1,
               path: ->(v) { v.order_correios_create_b2b_dashboard_index_path }, perm: 'dashboard_correios_b2b', active: page('dashboard', 'order_correios_create_b2b')),
          link('log02-criacao', 'Criação de Pedidos', 'fas fa-plus-circle', 'Cria no Correios os pedidos aprovados.', step: 2,
               path: ->(v) { v.order_correios_create_queue_b2b_dashboard_index_path }, perm: 'dashboard_correios_b2b', active: page('dashboard', 'order_correios_create_queue_b2b')),
          link('log02-notas', 'Emissão de Notas', 'fas fa-file-invoice', 'Pede ao Tiny a nota fiscal dos pedidos criados.', step: 3,
               path: ->(v) { v.invoice_emition_b2b_dashboard_index_path }, perm: 'dashboard_correios_b2b', active: page('dashboard', 'invoice_emition_b2b')),
          link('log02-xml', 'Enviar XML', 'fas fa-file-code', 'Envia ao Correios o arquivo da nota de cada pedido.', step: 4,
               path: ->(v) { v.send_xml_b2b_dashboard_index_path }, perm: 'dashboard_correios_b2b', active: page('dashboard', 'send_xml_b2b')),
          link('log02-rastreio', 'Rastreamento', 'fas fa-shipping-fast', 'Busca o código de rastreio e grava no Tiny.', step: 5,
               path: ->(v) { v.push_tracking_b2b_dashboard_index_path }, perm: 'dashboard_correios_b2b', active: page('dashboard', 'push_tracking_b2b')),
          sub('Consultas e ajustes'),
          link('log02-sem-estoque', 'Produtos Sem Estoque', 'fas fa-box-open', 'O que falta no armazém do atacado e os pedidos presos.',
               path: ->(v) { v.order_correios_stock_errors_b2b_dashboard_index_path }, perm: 'dashboard_correios_b2b', active: page('dashboard', 'order_correios_stock_errors_b2b')),
          link('log02-reservas', 'Reservas de Estoque', 'fas fa-lock', 'Quanto de cada produto já está comprometido em pedidos.',
               path: ->(v) { v.b2b_stock_reservations_path }, perm: 'stock_reservations_b2b', active: page('stock_reservations', 'b2b')),
          link('log02-tentativas', 'Tentativas', 'fas fa-list-check', 'Histórico de cada tentativa, com o erro e o "Reprocessar".',
               path: ->(v) { v.attempts_path(channel: 'b2b') }, perm: 'dashboard_correios_b2b', active: channel('b2b')),
          link('log02-api', 'API Correios', 'fas fa-cogs', 'Consulte estoque e rastreio direto no Correios (conta do atacado).',
               path: ->(v) { v.api_correios_b2b_dashboard_index_path }, perm: 'dashboard_correios_b2b', active: page('dashboard', 'api_correios_b2b'))
        ]),
        group('planejador', 'Planejador', 'fas fa-clipboard-list', 'Transforma uma planilha de produtos em nota de transferência no Tiny.', children: [
          link('plan-lista', 'Pedidos do Planejador', 'fas fa-list', 'Planilhas enviadas e se já viraram nota no Tiny.',
               path: ->(v) { v.planner_orders_path }, perm: 'planner_orders', active: page('planner_orders', 'index', 'show', 'edit', 'update')),
          link('plan-novo', 'Novo Pedido', 'fas fa-plus-circle', 'Suba o CSV (Name, SKU, Ordered) e transmita ao Tiny.',
               path: ->(v) { v.new_planner_order_path }, perm: 'planner_orders', act: 'C', active: page('planner_orders', 'new', 'create'))
        ]),
        link('log-abastecimento', 'Abastecimento Lojas', 'fas fa-dolly', 'Reponha as lojas com o estoque do Log02.',
             path: ->(v) { v.stock_transfers_path }, perm: 'store_supply', active: kind('stock_transfer')),
        link('log-locais', 'Locais de Transferência', 'fas fa-map-marker-alt', 'Destinos (CNPJ e endereço) usados nas transferências.',
             path: ->(v) { v.transfer_locations_path }, perm: 'transfer_locations', active: ctrl('transfer_locations')),
        link('log-transf-b2c', 'Transferência B2B → B2C', 'fas fa-random', 'Mande peças do estoque de atacado para a loja online.',
             path: ->(v) { v.b2c_transfers_path }, perm: 'b2b_transfers', active: kind('b2c_transfer'))
      ]),

      area('atacado', [
        link('atc-clientes', 'Cadastro de Clientes', 'fas fa-address-book', 'Cadastre e consulte os lojistas e empresas que compram no atacado.',
             path: ->(v) { v.clients_path }, perm: 'clients', active: ctrl('clients')),
        link('atc-pedidos', 'Pedidos de Atacado', 'fas fa-file-invoice-dollar', 'Cadastre vendas para lojistas e envie ao Tiny.',
             path: ->(v) { v.b2b_orders_path }, perm: 'b2b_orders', active: kind('sale')),
        link('atc-catalogos', 'Catálogos', 'fas fa-book-open', 'Monte catálogos e mande o link para lojistas encomendarem.',
             path: ->(v) { v.b2b_catalogs_path }, perm: 'b2b_catalogs', badge: :catalogs, active: ctrl('b2b_catalogs', 'b2b_catalog_orders'))
      ]),

      area('adm', [
        group('acessos', 'Acessos e equipe', 'fas fa-users-cog', 'Quem entra no sistema e o que cada pessoa pode ver e fazer.', children: [
          link('adm-usuarios', 'Gerenciar Usuários', 'fas fa-users-cog', 'Crie e edite quem acessa o painel.',
               path: ->(v) { v.users_path }, perm: 'users_management', active: ->(v) { v.controller_path == 'users' && !(v.action_name.in?(%w[edit update]) && v.params[:id].to_s == v.current_user.id.to_s) }),
          link('adm-perfis', 'Perfis e Permissões', 'fas fa-user-shield', 'Defina o que cada perfil vê e faz: por área, por loja e por ação.',
               path: ->(v) { v.profiles_path }, cond: :admin, active: ctrl('profiles')),
          link('adm-setores', 'Setores de chamados', 'fas fa-building', 'Agrupam as áreas que recebem chamados.',
               path: ->(v) { v.ticket_sectors_path }, cond: :admin, active: ctrl('ticket_sectors')),
          link('adm-resp', 'Responsabilidades', 'fas fa-sitemap', 'Áreas que recebem chamados, com responsáveis e prazo.',
               path: ->(v) { v.ticket_responsabilities_path }, cond: :admin, active: ctrl('ticket_responsabilities'))
        ]),
        group('fiscal', 'Fiscal e cadastros', 'fas fa-receipt', 'Notas fiscais, empresas emissoras e transportadoras.', children: [
          link('adm-notas', 'Notas Fiscais', 'fas fa-file-invoice', 'Emita e transmita a NF-e direto na SEFAZ.',
               path: ->(v) { v.fiscal_notes_path }, perm: 'fiscal_notes', active: ctrl('fiscal_notes')),
          link('fiscal-produtos', 'Dados fiscais dos produtos', 'fas fa-receipt', 'NCM, CEST, origem e unidade usados na nota.',
               path: ->(v) { v.fiscal_products_path }, perm: 'fiscal_notes', active: ctrl('fiscal_products')),
          link('adm-empresas', 'Empresas', 'fas fa-building', 'CNPJs que emitem nota, com certificado digital.',
               path: ->(v) { v.companies_path }, perm: 'companies', active: ctrl('companies')),
          link('adm-naturezas', 'Naturezas de Operação', 'fas fa-tags', 'CFOP e textos de cada tipo de operação da nota.',
               path: ->(v) { v.operation_natures_path }, perm: 'companies', active: ctrl('operation_natures')),
          link('adm-transportadoras', 'Transportadoras', 'fas fa-truck-moving', 'Transportadoras usadas nos pedidos de atacado.',
               path: ->(v) { v.carriers_path }, perm: 'carriers', active: ctrl('carriers'))
        ])
      ])
    ].freeze
  end

  # Telas fora do menu que a busca rápida também encontra.
  def extras
    @extras ||= [
      link('meu-perfil', 'Meu Perfil', 'fas fa-user-edit', 'Troque sua foto, telefone e senha.', section: 'Sua conta',
           keys: 'senha foto telefone conta', path: ->(v) { v.edit_user_path(v.current_user) },
           active: ->(v) { v.controller_path == 'users' && v.action_name.in?(%w[edit update]) && v.params[:id].to_s == v.current_user.id.to_s }),
      link('novo-pedido-atacado', 'Novo Pedido de Atacado', 'fas fa-file-invoice-dollar', 'Cadastre uma venda para lojista.', section: 'Ações',
           keys: 'novo pedido b2b venda lojista', perm: 'b2b_orders', act: 'C', path: ->(v) { v.new_b2b_order_path }),
      link('novo-cliente-atacado', 'Novo cliente de atacado', 'fas fa-address-book', 'Cadastre um lojista ou empresa.', section: 'Ações',
           keys: 'novo cliente lojista cnpj cadastrar', perm: 'clients', act: 'C', path: ->(v) { v.new_client_path }),
      link('nova-conferencia', 'Nova Conferência de Estoque', 'fas fa-warehouse', 'Comece a contagem de uma loja.', section: 'Ações',
           keys: 'contagem inventario', perm: 'stock_corrections', act: 'C', path: ->(v) { v.new_stock_correction_path }),
      link('nova-retirada', 'Nova Retirada de Estoque', 'fas fa-dolly-flatbed', 'Baixa por perda, dano ou marketing.', section: 'Ações',
           keys: 'perda quebra dano baixa', perm: 'stock_withdrawals', act: 'C', path: ->(v) { v.new_stock_withdrawal_path }),
      link('nova-transferencia', 'Nova Transferência de Estoque', 'fas fa-exchange-alt', 'Peça peças de outra loja.', section: 'Ações',
           keys: 'pedir peca outra loja interna', perm: 'internal_transfers', act: 'C', path: ->(v) { v.new_internal_transfer_path }),
      link('novo-catalogo', 'Novo catálogo', 'fas fa-book-open', 'Monte um catálogo para lojistas.', section: 'Ações',
           keys: 'colecao link lojista', perm: 'b2b_catalogs', act: 'C', path: ->(v) { v.new_b2b_catalog_path }),
      link('nova-nota-shopify', 'Nota de pedido Shopify', 'fas fa-file-invoice', 'Emita a NF-e de um pedido da loja online.', section: 'Ações',
           keys: 'nota nfe shopify consumidor emitir', perm: 'fiscal_notes', act: 'C', path: ->(v) { v.shopify_fiscal_notes_path })
    ].freeze
  end

  def area(id, items) = { type: :area, id: id, **Screen::AREAS.fetch(id), items: items }
  def group(id, label, icon, desc, children:, **opts) = { type: :group, id: id, label: label, icon: icon, desc: desc, children: children, **opts }
  def link(id, label, icon, desc, **opts) = { type: :link, id: id, label: label, icon: icon, desc: desc, **opts }
  def sub(label, steps: false) = { type: :sub, label: label, steps: steps }

  # Item liberado para o usuário (sem considerar grupos).
  def allowed?(item, user)
    return false if item[:cond] == :admin && !user.admin?
    return false if item[:cond] == :sectors_non_admin && (user.admin? || user.visible_ticket_sector_ids.empty?)
    return true unless item[:perm]

    user.can?(item[:perm], item[:act] || 'V')
  end

  # Menu só com o que o usuário pode abrir: grupos e áreas vazios somem, e os títulos de
  # subseção sem itens depois deles também.
  def for(user)
    menu.filter_map do |area|
      items = area[:items].filter_map do |item|
        next (allowed?(item, user) ? item : nil) unless item[:type] == :group

        children = prune_subs(item[:children].select { |c| c[:type] == :sub || allowed?(c, user) })
        children.any? { |c| c[:type] == :link } ? item.merge(children: children) : nil
      end
      items.any? ? area.merge(items: items) : nil
    end
  end

  def prune_subs(children)
    children.each_with_index.reject do |child, i|
      child[:type] == :sub && (children[i + 1].nil? || children[i + 1][:type] == :sub)
    end.map(&:first)
  end

  # Todos os itens (com área e grupo) — usado para achar a tela atual e montar a busca.
  def flatten(menu)
    menu.flat_map do |area|
      area[:items].flat_map do |item|
        if item[:type] == :group
          item[:children].select { |c| c[:type] == :link }.map { |c| { item: c, area: area, group: item } }
        else
          [{ item: item, area: area, group: nil }]
        end
      end
    end
  end

  def help
    @help ||= JSON.parse(Rails.root.join('config/honey/help.json').read)
  end
end
