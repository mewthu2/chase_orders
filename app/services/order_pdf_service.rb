require 'prawn'
require 'prawn/table'

class OrderPdfService
  include Prawn::View

  BRAND_DARK    = '0D1117'
  BRAND_SURFACE = '161B22'
  BRAND_BORDER  = '21262D'
  BRAND_TEXT    = 'E6EDF3'
  BRAND_MUTED   = '8B949E'
  BRAND_BLUE    = '1F6FEB'
  BRAND_GREEN   = '238636'
  BRAND_YELLOW  = 'D29922'

  def initialize(order)
    @order = order
    @items = order.order_pdv_items.includes(:product)
    @parcels = order.order_parcels
  end

  def generate
    Prawn::Document.new(
      page_size:    'A4',
      page_layout:  :portrait,
      margin:       [40, 50, 40, 50],
      info: {
        Title:   "Pedido ##{@order.id}",
        Author:  'ChaseOrders',
        Subject: 'Proposta de Pedido para Aprovação',
        Creator: 'ChaseOrders PDV'
      }
    ) do |pdf|
      build(pdf)
    end
  end

  private

  def build(pdf)
    draw_header(pdf)
    pdf.move_down 20
    draw_order_info(pdf)
    pdf.move_down 16

    if @order.client.present?
      draw_client_section(pdf)
      pdf.move_down 16
    end

    draw_items_table(pdf)
    pdf.move_down 16
    draw_totals(pdf)

    if @parcels.any?
      pdf.move_down 16
      draw_parcels(pdf)
    end

    if @order.order_note.present?
      pdf.move_down 16
      draw_notes(pdf)
    end

    pdf.move_down 30
    draw_approval_section(pdf)
    draw_footer(pdf)
  end

  # ── Header ────────────────────────────────────────────────────────────────
  def draw_header(pdf)
    pdf.fill_color BRAND_DARK
    pdf.fill_rectangle [0, pdf.cursor + 10], pdf.bounds.width, 70
    pdf.fill_color BRAND_TEXT

    pdf.bounding_box([10, pdf.cursor - 2], width: pdf.bounds.width - 20, height: 60) do
      pdf.text 'PROPOSTA DE PEDIDO', size: 20, style: :bold, color: BRAND_TEXT
      pdf.move_down 4
      pdf.text "Pedido ##{@order.id}  ·  #{I18n.l(@order.created_at, format: '%d/%m/%Y às %H:%M') rescue @order.created_at.strftime('%d/%m/%Y às %H:%M')}",
               size: 9, color: BRAND_MUTED
    end

    pdf.move_down 10

    status_label, status_color = status_info(@order.status)
    pdf.fill_color status_color
    pdf.rounded_rectangle [0, pdf.cursor], 110, 22, 4
    pdf.fill_color BRAND_TEXT
    pdf.draw_text status_label,
                  at: [8, pdf.cursor - 15],
                  size: 9, style: :bold
    pdf.stroke_color BRAND_BORDER

    pdf.move_down 28
    pdf.stroke_color BRAND_BORDER
    pdf.line_width 0.5
    pdf.stroke_horizontal_rule
  end

  # ── Informações do Pedido ─────────────────────────────────────────────────
  def draw_order_info(pdf)
    section_title(pdf, 'Informações do Pedido')
    pdf.move_down 8

    cols = [
      ['Número do Pedido', "##{@order.id}"],
      ['Data de Criação', @order.created_at.strftime('%d/%m/%Y')],
      ['Status', status_info(@order.status).first],
      ['Forma de Pagamento', humanize_payment(@order.payment_method)]
    ]

    if @order.tiny_order_id.present?
      cols << ['Tiny ERP', "##{@order.tiny_order_id}"]
    end

    cols += [
      ['Vendedor', @order.user&.name || @order.user&.email || '—'],
      ['Endereço', [@order.address1, @order.address2].select(&:present?).join(' — ')],
      ['Cidade / Estado', "#{@order.city} / #{@order.state}"],
      ['CEP', @order.zip]
    ]

    cols.each_slice(2) do |pair|
      y = pdf.cursor
      pair.each_with_index do |(label, value), i|
        x = i == 0 ? 0 : pdf.bounds.width / 2
        w = pdf.bounds.width / 2 - 10
        pdf.bounding_box([x, y], width: w) do
          pdf.fill_color BRAND_MUTED
          pdf.text label.to_s, size: 7.5, style: :bold
          pdf.fill_color BRAND_TEXT
          pdf.text value.to_s.presence || '—', size: 9
        end
      end
      pdf.move_down 22
    end
  end

  # ── Cliente ───────────────────────────────────────────────────────────────
  def draw_client_section(pdf)
    section_title(pdf, 'Cliente')
    pdf.move_down 8

    c = @order.client
    fields = {
      'Responsável'         => c.responsible_name,
      'Razão Social'        => c.business_name,
      'CNPJ'                => c.respond_to?(:cnpj_formatted) ? c.cnpj_formatted : c.registration,
      'Inscrição Estadual'  => c.respond_to?(:state_registration) ? c.state_registration : nil,
      'E-mail'              => c.respond_to?(:email) ? c.email : nil,
      'Telefone'            => c.respond_to?(:phone) ? c.phone : nil
    }.select { |_, v| v.present? }

    fields.each_slice(3) do |group|
      y = pdf.cursor
      group.each_with_index do |(label, value), i|
        x = i * (pdf.bounds.width / 3)
        w = pdf.bounds.width / 3 - 10
        pdf.bounding_box([x, y], width: w) do
          pdf.fill_color BRAND_MUTED
          pdf.text label, size: 7.5, style: :bold
          pdf.fill_color BRAND_TEXT
          pdf.text value.to_s, size: 9
        end
      end
      pdf.move_down 22
    end
  end

  # ── Tabela de Itens ───────────────────────────────────────────────────────
  def draw_items_table(pdf)
    section_title(pdf, 'Itens do Pedido')
    pdf.move_down 8

    header = [
      pdf.make_cell(content: 'SKU',       font_style: :bold, background_color: BRAND_SURFACE, text_color: BRAND_MUTED, size: 8),
      pdf.make_cell(content: 'Produto',   font_style: :bold, background_color: BRAND_SURFACE, text_color: BRAND_MUTED, size: 8),
      pdf.make_cell(content: 'Qtd',       font_style: :bold, background_color: BRAND_SURFACE, text_color: BRAND_MUTED, size: 8, align: :center),
      pdf.make_cell(content: 'Unit.',     font_style: :bold, background_color: BRAND_SURFACE, text_color: BRAND_MUTED, size: 8, align: :right),
      pdf.make_cell(content: 'Total',     font_style: :bold, background_color: BRAND_SURFACE, text_color: BRAND_MUTED, size: 8, align: :right)
    ]

    rows = @items.map do |item|
      [
        { content: item.sku.to_s,          size: 8, text_color: BRAND_MUTED,  background_color: BRAND_DARK },
        { content: item.product_name.to_s, size: 9, text_color: BRAND_TEXT,   background_color: BRAND_DARK },
        { content: item.quantity.to_s,     size: 9, text_color: BRAND_TEXT,   background_color: BRAND_DARK, align: :center },
        { content: format_brl(item.price), size: 9, text_color: BRAND_TEXT,   background_color: BRAND_DARK, align: :right },
        { content: format_brl(item.total), size: 9, text_color: BRAND_GREEN,  background_color: BRAND_DARK, align: :right, font_style: :bold }
      ]
    end

    pdf.table([header] + rows,
      width:        pdf.bounds.width,
      cell_style:   { padding: [6, 8], border_color: BRAND_BORDER, border_width: 0.5 },
      column_widths: [70, nil, 40, 70, 80]
    ) do |t|
      t.columns(0..-1).border_color = BRAND_BORDER
      t.row(0).border_bottom_width  = 1
      t.row(0).border_bottom_color  = BRAND_BLUE
    end
  end

  # ── Totais ────────────────────────────────────────────────────────────────
  def draw_totals(pdf)
    w      = 200
    x      = pdf.bounds.width - w

    rows = []
    rows << ['Subtotal', format_brl(@order.subtotal)]

    if @order.discount_amount.to_f > 0
      rows << ["Desconto#{@order.discount_reason.present? ? " (#{@order.discount_reason})" : ''}", "- #{format_brl(@order.discount_amount)}"]
    end

    if @order.coupon_discount_amount.to_f > 0
      rows << ["Cupom #{@order.coupon_code}", "- #{format_brl(@order.coupon_discount_amount)}"]
    end

    pdf.bounding_box([x, pdf.cursor], width: w) do
      rows.each do |label, value|
        pdf.fill_color BRAND_MUTED
        pdf.text_box label,  at: [0, pdf.cursor],       width: w - 80, size: 8, align: :left
        pdf.fill_color BRAND_TEXT
        pdf.text_box value,  at: [w - 80, pdf.cursor],  width: 80,    size: 8, align: :right
        pdf.move_down 14
      end

      pdf.stroke_color BRAND_BORDER
      pdf.line_width 0.5
      pdf.stroke_horizontal_rule
      pdf.move_down 8

      pdf.fill_color BRAND_TEXT
      pdf.text_box 'Total', at: [0, pdf.cursor],      width: w - 90, size: 12, style: :bold, color: BRAND_TEXT
      pdf.fill_color BRAND_GREEN
      pdf.text_box @order.formatted_total, at: [w - 90, pdf.cursor], width: 90, size: 12, style: :bold, align: :right
      pdf.move_down 18
    end
  end

  # ── Parcelas ──────────────────────────────────────────────────────────────
  def draw_parcels(pdf)
    section_title(pdf, 'Formas de Pagamento')
    pdf.move_down 8

    header = [
      pdf.make_cell(content: '#',              font_style: :bold, background_color: BRAND_SURFACE, text_color: BRAND_MUTED, size: 8),
      pdf.make_cell(content: 'Forma',          font_style: :bold, background_color: BRAND_SURFACE, text_color: BRAND_MUTED, size: 8),
      pdf.make_cell(content: 'Valor',          font_style: :bold, background_color: BRAND_SURFACE, text_color: BRAND_MUTED, size: 8, align: :right),
      pdf.make_cell(content: 'Observação',     font_style: :bold, background_color: BRAND_SURFACE, text_color: BRAND_MUTED, size: 8)
    ]

    rows = @parcels.map.with_index(1) do |p, i|
      [
        { content: i.to_s,                          size: 8, text_color: BRAND_MUTED,  background_color: BRAND_DARK },
        { content: humanize_payment(p.payment_method), size: 9, text_color: BRAND_TEXT, background_color: BRAND_DARK },
        { content: format_brl(p.amount),            size: 9, text_color: BRAND_GREEN,  background_color: BRAND_DARK, align: :right, font_style: :bold },
        { content: p.notes.to_s,                    size: 8, text_color: BRAND_MUTED,  background_color: BRAND_DARK }
      ]
    end

    pdf.table([header] + rows,
      width:      pdf.bounds.width,
      cell_style: { padding: [5, 8], border_color: BRAND_BORDER, border_width: 0.5 }
    )
  end

  # ── Notas ─────────────────────────────────────────────────────────────────
  def draw_notes(pdf)
    section_title(pdf, 'Observações')
    pdf.move_down 8
    pdf.fill_color BRAND_TEXT
    pdf.text @order.order_note, size: 9, leading: 4
  end

  # ── Área de Aprovação ─────────────────────────────────────────────────────
  def draw_approval_section(pdf)
    pdf.stroke_color BRAND_BORDER
    pdf.line_width 0.5
    pdf.stroke_horizontal_rule
    pdf.move_down 20

    section_title(pdf, 'Aprovação do Pedido')
    pdf.move_down 12

    pdf.fill_color BRAND_MUTED
    pdf.text 'Ao assinar abaixo, o cliente declara estar ciente e de acordo com todos os itens,', size: 8
    pdf.text 'quantidades, valores e condições de pagamento descritos neste documento.', size: 8
    pdf.move_down 24

    half = (pdf.bounds.width - 40) / 2
    pdf.fill_color BRAND_BORDER
    pdf.fill_rectangle [0, pdf.cursor + 1], half, 1
    pdf.fill_rectangle [half + 40, pdf.cursor + 1], half, 1

    pdf.move_down 8
    pdf.fill_color BRAND_MUTED
    pdf.text_box 'Assinatura do Cliente',      at: [0, pdf.cursor],        width: half, size: 7.5, align: :center
    pdf.text_box 'Assinatura do Responsável',  at: [half + 40, pdf.cursor], width: half, size: 7.5, align: :center
    pdf.move_down 24

    half_date = 120
    pdf.fill_color BRAND_BORDER
    pdf.fill_rectangle [0, pdf.cursor + 1], half_date, 1
    pdf.move_down 8
    pdf.fill_color BRAND_MUTED
    pdf.text_box 'Data', at: [0, pdf.cursor], width: half_date, size: 7.5, align: :center
  end

  # ── Footer ────────────────────────────────────────────────────────────────
  def draw_footer(pdf)
    pdf.repeat(:all) do
      pdf.bounding_box([0, pdf.bounds.absolute_bottom + 24], width: pdf.bounds.width) do
        pdf.stroke_color BRAND_BORDER
        pdf.line_width 0.3
        pdf.stroke_horizontal_rule
        pdf.move_down 6
        pdf.fill_color BRAND_MUTED
        pdf.text "Documento gerado em #{Time.current.strftime('%d/%m/%Y às %H:%M')} · Pedido ##{@order.id} · ChaseOrders",
                 size: 7, align: :center
      end
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────
  def section_title(pdf, text)
    pdf.fill_color BRAND_MUTED
    pdf.text text.upcase, size: 7.5, style: :bold, character_spacing: 1.2
    pdf.move_down 2
    pdf.fill_color BRAND_BLUE
    pdf.fill_rectangle [0, pdf.cursor], 36, 2
    pdf.fill_color BRAND_DARK
    pdf.move_down 4
  end

  def format_brl(value)
    "R$ #{sprintf('%.2f', value.to_f).gsub('.', ',')}"
  end

  def humanize_payment(method)
    return '—' if method.blank?
    {
      'dinheiro'       => 'Dinheiro',
      'cartao_credito' => 'Cartão de Crédito',
      'cartao_debito'  => 'Cartão de Débito',
      'pix'            => 'PIX',
      'boleto'         => 'Boleto',
      'transferencia'  => 'Transferência'
    }.fetch(method.to_s, method.to_s.humanize)
  end

  def status_info(status)
    {
      'pending'    => ['Pendente',     BRAND_YELLOW],
      'integrated' => ['Integrado',    BRAND_BLUE],
      'paid'       => ['Pago',         BRAND_GREEN],
      'incomplete' => ['Incompleto',   'D29922'],
      'error'      => ['Erro',         'DA3633']
    }.fetch(status.to_s, [status.to_s.humanize, BRAND_MUTED])
  end
end
