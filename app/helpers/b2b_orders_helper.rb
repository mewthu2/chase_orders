module B2bOrdersHelper
  def tiny_order_url(order)
    return nil if order.tiny_reference_id.blank?

    base = order.tiny_order? ? ENV.fetch('TINY_ORDER_URL', 'https://erp.tiny.com.br/vendas#edit/') : ENV.fetch('TINY_NOTA_FISCAL_URL', 'https://erp.tiny.com.br/notas_fiscais#edit/')
    "#{base}#{order.tiny_reference_id}"
  end

  # Textos de cada tela de pedido B2B (atacado, abastecimento das lojas e transferência B2C).
  B2B_SCREEN_COPY = {
    'sale' => { title: 'Pedidos de Atacado', new_title: 'Novo Pedido de Atacado', edit_title: 'Editar Pedido de Atacado',
                icon: 'handshake', subtitle: 'Pedidos de venda no atacado', list_title: 'Lista de Pedidos',
                new_button: 'Novo Pedido', empty: 'Nenhum pedido cadastrado' },
    'stock_transfer' => { title: 'Abastecimento Lojas', new_title: 'Novo Abastecimento Lojas', edit_title: 'Editar Abastecimento Lojas',
                          icon: 'dolly', subtitle: 'Transferências de estoque para abastecer as lojas', list_title: 'Lista de Abastecimentos',
                          new_button: 'Novo Abastecimento', empty: 'Nenhum abastecimento cadastrado' },
    'b2c_transfer' => { title: 'Transferência B2B → B2C', new_title: 'Nova Transferência B2B → B2C', edit_title: 'Editar Transferência B2B → B2C',
                        icon: 'random', subtitle: 'Transferências do estoque B2B para a filial B2C (CNPJ 25.405.327/0003-36)',
                        list_title: 'Lista de Transferências', new_button: 'Nova Transferência', empty: 'Nenhuma transferência cadastrada' }
  }.freeze

  def b2b_screen_copy(kind)
    B2B_SCREEN_COPY.fetch(kind.to_s)
  end

  # Pedido já no Tiny é cancelado lá antes de sair do Honey (a API do Tiny não exclui pedido).
  def b2b_delete_confirm(order)
    if order.tiny_reference_id.present?
      number = order.tiny_reference_number.presence || order.tiny_reference_id
      "Excluir o pedido ##{order.id}? Ele será CANCELADO no Tiny (nº #{number}) e removido do Honey com os itens. " \
        'O cancelado continua no Tiny e pode ser excluído por lá.'
    else
      "Excluir o pedido ##{order.id}? Ele não foi enviado ao Tiny. A exclusão remove o pedido e os itens do Honey."
    end
  end

  B2B_ORDER_TYPE_ICONS = { store_supply: 'dolly', b2c_transfer: 'random', sale: 'handshake' }.freeze

  # Selo do tipo do pedido (B2bOrderType) nas telas do Correios B2B.
  def b2b_order_type_badge(type)
    label = B2bOrderType.label(type)
    return if label.nil?

    content_tag(:span, class: "b2b-order-type-badge type-#{type}", title: "Tipo do pedido: #{label}") do
      concat content_tag(:i, '', class: "fas fa-#{B2B_ORDER_TYPE_ICONS[type.to_sym]}")
      concat label
    end
  end

  def b2b_order_destination(order)
    if order.sale? then order.client&.display_name
    elsif order.stock_transfer? then order.transfer_location&.name
    else B2bTinyService::B2C_TRANSFER_RECIPIENT[:nome]
    end
  end
end
