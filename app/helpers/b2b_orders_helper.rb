module B2bOrdersHelper
  # Tela do pedido no Honey, conforme o tipo (atacado, abastecimento ou transferência B2C).
  def b2b_order_edit_path(order, **opts)
    if order.sale? then edit_b2b_order_path(order, **opts)
    elsif order.stock_transfer? then edit_stock_transfer_path(order, **opts)
    else edit_b2c_transfer_path(order, **opts)
    end
  end

  B2B_NOTE_TONES = { 'autorizada' => ['is-ok', 'autorizada'], 'rejeitada' => ['is-err', 'rejeitada'], 'erro' => ['is-wait', 'sem resposta da SEFAZ'],
                     'assinada' => ['is-wait', 'assinada, falta enviar à SEFAZ'], 'rascunho' => ['is-wait', 'gerada, falta emitir'] }.freeze

  # Número do pedido com o P (abre o pedido) e o N (abre a aba da nota, na cor da situação dela).
  # note: { environment:, status:, number: } de FiscalNote.latest_by_order, ou nil.
  # remessa: o mesmo para a nota de remessa (o N.r), nos pedidos que têm remessa (B2bOrder#remessa_note?).
  # O número de cada nota vai dentro do quadrado (ex.: N 1324, N.r 1325).
  def b2b_pn_cell(order, note, remessa: nil)
    letters = [link_to('P', b2b_order_edit_path(order), class: 'pg-pn', data: { tip: 'Pedido: abrir e editar' }, 'aria-label': 'Abrir o pedido'),
               b2b_note_letter(order, note)]
    letters << b2b_note_letter(order, remessa, remessa: true) if order.remessa_note?
    safe_join([content_tag(:span, "##{order.id}", class: 'num'), content_tag(:span, safe_join(letters), class: 'pg-pn-group')])
  end

  def b2b_note_letter(order, note, remessa: false)
    tone, label = note ? B2B_NOTE_TONES.fetch(note[:status], ['is-wait', note[:status]]) : ['is-none', nil]
    what = remessa ? 'Nota de remessa' : 'Nota fiscal'
    tip = if note
            "#{what}: NF-e nº #{note[:number]}#{' (homologação)' if note[:environment] == 'homologacao'}, #{label}." +
              (note[:status] == 'autorizada' ? '' : ' Dá para corrigir e emitir de novo.')
          else
            "#{what}: ainda não emitida. Clique para emitir."
          end
    path = b2b_order_edit_path(order, tab: 'nota', anchor: ('remessaNote' if remessa))
    mark = remessa ? 'N.r' : 'N'
    # O número da nota vai dentro do quadrado, na cor da situação dela (verde se autorizada).
    body = note ? safe_join([content_tag(:span, mark, class: 'pg-pn-l'), content_tag(:span, note[:number], class: 'pg-pn-num')]) : mark
    link_to(body, path, class: "pg-pn #{tone}#{' pg-pn--wide' if note || remessa}#{' pg-pn--remessa' if remessa}", data: { tip: tip },
                        'aria-label': remessa ? 'Abrir a nota de remessa' : 'Abrir a nota fiscal')
  end

  # Número do pedido no Correios com a bandeirinha nas cores do Correios, para identificar de relance.
  def b2b_correios_number(number)
    return content_tag(:span, '—', class: 'pg-dash') if number.blank?

    flag = content_tag(:span, content_tag(:i, '', class: 'fas fa-envelope'), class: 'correios-flag', 'aria-hidden': true)
    content_tag(:span, flag + content_tag(:span, number, class: 'mono pg-mono'), class: 'correios-number', data: { tip: 'Número do pedido no Correios' })
  end

  # Pedidos do Honey das linhas do Log02, pelo id do Tiny 2 (os que foram ao Tiny guardam o id em
  # tiny_reference_id). Devolve { 'id do Tiny' => B2bOrder }.
  def b2b_honey_orders_by_tiny(tiny_ids)
    ids = Array(tiny_ids).map(&:to_s).reject(&:blank?).uniq
    return {} if ids.empty?

    B2bOrder.where(tiny_reference_id: ids).index_by { |o| o.tiny_reference_id.to_s }
  end

  # Botão da linha nas telas do Log02: o B2B não está mais no Tiny, então abre o pedido no Honey.
  # Pedido antigo feito direto no Tiny 2 não tem pedido no Honey: o botão aparece apagado e explica.
  def b2b_honey_order_action(order)
    if order
      tip = "Ver o pedido ##{order.id} no Honey"
      link_to(content_tag(:i, '', class: 'fas fa-eye'), b2b_order_edit_path(order), class: 'action-btn', target: '_blank', rel: 'noopener',
                                                                                    data: { tip: tip }, 'aria-label': tip)
    else
      tip = 'Pedido antigo, feito direto no Tiny 2: não existe no Honey'
      content_tag(:span, content_tag(:i, '', class: 'fas fa-eye-slash'), class: 'action-btn', style: 'opacity:.4;cursor:default',
                                                                          data: { tip: tip }, 'aria-label': tip)
    end
  end

  # Textos de cada tela de pedido B2B (atacado, abastecimento das lojas e transferência B2C).
  B2B_SCREEN_COPY = {
    'sale' => { title: 'Pedidos de Atacado', new_title: 'Novo Pedido de Atacado', edit_title: 'Editar Pedido de Atacado',
                icon: 'handshake', subtitle: 'Pedidos de venda no atacado', list_title: 'Lista de Pedidos',
                new_button: 'Novo Pedido', empty: 'Nenhum pedido cadastrado' },
    'stock_transfer' => { title: 'Abastecimento Lojas', new_title: 'Novo Abastecimento Lojas', edit_title: 'Editar Abastecimento Lojas',
                          icon: 'dolly', subtitle: 'Transferências de estoque para abastecer as lojas', list_title: 'Lista de Abastecimentos',
                          new_button: 'Novo Abastecimento', empty: 'Nenhum abastecimento cadastrado' },
    'b2c_transfer' => { title: 'Transferências B2B ⇄ B2C', new_title: 'Nova Transferência B2B → B2C', edit_title: 'Editar Transferência B2B → B2C',
                        icon: 'random', subtitle: 'Transferências do estoque B2B para a filial B2C (CNPJ 25.405.327/0003-36)',
                        list_title: 'Lista de Transferências', new_button: 'Nova Transferência', empty: 'Nenhuma transferência cadastrada' }
  }.freeze

  B2C_TO_B2B_COPY = { new_title: 'Nova Transferência B2C → B2B', edit_title: 'Editar Transferência B2C → B2B' }.freeze

  def b2b_screen_copy(kind, order = nil)
    copy = B2B_SCREEN_COPY.fetch(kind.to_s)
    order&.b2c_to_b2b? ? copy.merge(B2C_TO_B2B_COPY) : copy
  end

  # O Tiny 2 não é mais usado: excluir só tira o pedido do Honey.
  def b2b_delete_confirm(order)
    "Excluir o pedido ##{order.id}? A exclusão remove o pedido e os itens do Honey."
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
    elsif order.b2c_to_b2b? then 'Filial B2B'
    else B2bTinyService::B2C_TRANSFER_RECIPIENT[:nome]
    end
  end
end
