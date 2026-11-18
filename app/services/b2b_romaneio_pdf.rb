require 'prawn'
require 'prawn/table'
require 'net/http'

Prawn::Fonts::AFM.hide_m17n_warning = true

# Romaneio do pedido B2B: a lista de itens em PDF, para mandar ao cliente por WhatsApp ou e-mail.
class B2bRomaneioPdf
  NAVY = '0D1B2A'.freeze
  BLUE = '1F6FEB'.freeze
  SKY = '58A6FF'.freeze
  INK = '1F2328'.freeze
  MUTED = '6E7781'.freeze
  ZEBRA = 'F3F7FD'.freeze
  LINE = 'D8DEE4'.freeze

  LOGO_WHITE = Rails.root.join('app/assets/images/chase-logo-white.png').to_s.freeze

  # Foto do produto na tabela de itens: miniatura pedida já pequena à CDN da Shopify.
  PHOTO_SIZE = 34
  PHOTO_WIDTH_PX = 160
  PHOTO_TIMEOUT = 5
  PHOTO_THREADS = 12

  TITLES = { 'sale' => 'Pedido', 'stock_transfer' => 'Abastecimento', 'b2c_transfer' => 'Transferência B2B > B2C' }.freeze

  def initialize(order)
    @order = order
    @items = order.b2b_order_items.sort_by(&:id)
  end

  def filename
    base = "romaneio-pedido-#{@order.id}"
    destination = I18n.transliterate(destination_name.to_s).parameterize
    destination.present? ? "#{base}-#{destination}.pdf" : "#{base}.pdf"
  end

  def render
    pdf = Prawn::Document.new(page_size: 'A4', margin: [36, 36, 50, 36], info: { Title: "Romaneio ##{@order.id}", Creator: 'Honey Chase' })
    pdf.font 'Helvetica'
    @pdf = pdf

    header
    parties
    items_table
    totals
    notes
    footer
    pdf.render
  end

  private

  attr_reader :pdf

  def header
    width = pdf.bounds.width
    pdf.fill_color NAVY
    pdf.fill_rounded_rectangle [0, pdf.cursor], width, 78, 8
    # faixa de destaque em degradê na base do cabeçalho
    pdf.fill_gradient [0, pdf.cursor - 74], [width, pdf.cursor - 74], BLUE, SKY
    pdf.fill_rectangle [0, pdf.cursor - 74], width, 4

    top = pdf.cursor
    pdf.bounding_box([18, top - 16], width: width / 2) do
      pdf.image LOGO_WHITE, height: 22
      pdf.move_down 8
      pdf.fill_color SKY
      pdf.text 'ROMANEIO DE MERCADORIAS', size: 9, style: :bold, character_spacing: 1.5
    end
    pdf.bounding_box([width / 2, top - 14], width: width / 2 - 18) do
      pdf.fill_color 'FFFFFF'
      pdf.text "#{@order.b2c_to_b2b? ? 'Transferência B2C > B2B' : TITLES[@order.kind]} ##{@order.id}", size: 16, style: :bold, align: :right
      pdf.fill_color 'C9D1D9'
      pdf.text "Emitido em #{@order.created_at.strftime('%d/%m/%Y')}", size: 9, align: :right
      if @order.tiny_reference_number.present?
        pdf.text "Pedido Tiny nº #{@order.tiny_reference_number}", size: 9, align: :right
      end
    end
    pdf.move_cursor_to top - 78 - 18
    pdf.fill_color INK
  end

  def parties
    gap = 14
    col = (pdf.bounds.width - gap) / 2
    top = pdf.cursor

    pdf.bounding_box([0, top], width: col) do
      card_title(@order.sale? ? 'Cliente' : 'Destino')
      destination_lines.each { |line| info_line(*line) }
    end
    left_bottom = pdf.cursor

    pdf.bounding_box([col + gap, top], width: col) do
      card_title('Entrega')
      shipping_lines.each { |line| info_line(*line) }
    end
    pdf.move_cursor_to [left_bottom, pdf.cursor].min - 16
  end

  def card_title(label)
    pdf.fill_color BLUE
    pdf.text label.upcase, size: 8, style: :bold, character_spacing: 1.2
    pdf.stroke_color BLUE
    pdf.line_width 1.5
    pdf.stroke_horizontal_line 0, 28, at: pdf.cursor - 2
    pdf.move_down 8
    pdf.fill_color INK
  end

  def info_line(label, value)
    return if value.blank?

    if label
      pdf.formatted_text [{ text: "#{label}: ", styles: [:bold], color: MUTED, size: 9 }, { text: safe(value), size: 9 }], leading: 2
    else
      pdf.text safe(value), size: 10.5, style: :bold, leading: 2
    end
  end

  def destination_lines
    if @order.sale?
      client = @order.client
      [[nil, client&.display_name],
       ['Responsável', (client&.responsible_name if client&.business_name.present?)],
       ['CNPJ/CPF', client&.cnpj_formatted],
       ['Telefone', client&.phone],
       ['E-mail', client&.email]]
    elsif @order.stock_transfer?
      location = @order.transfer_location
      [[nil, location&.name], ['CNPJ', location&.registration]]
    elsif @order.b2c_to_b2b?
      [[nil, b2b_branch&.legal_name], ['CNPJ', b2b_branch&.cnpj_formatted]]
    else
      recipient = B2bTinyService::B2C_TRANSFER_RECIPIENT
      [[nil, recipient[:nome]], ['CNPJ', recipient[:cpf_cnpj]]]
    end
  end

  def shipping_lines
    [['Endereço', shipping_address],
     ['Transportadora', @order.pickup? ? 'Retirada' : [@order.carrier&.name || @order.carrier_name, @order.freight_service].compact_blank.uniq.join(' · ')],
     ['Frete por conta', freight_payer],
     ['Vendedor(a)', @order.salesperson_name]]
  end

  def shipping_address
    parts = if @order.different_shipping_address?
              [@order.shipping_street, @order.shipping_number, @order.shipping_complement, @order.shipping_neighbourhood,
               city_state(@order.shipping_city, @order.shipping_state), @order.shipping_zip]
            elsif @order.sale? && @order.client
              c = @order.client
              [c.street, c.number, c.neighbourhood, city_state(c.city, c.state), c.zip]
            elsif @order.stock_transfer? && @order.transfer_location
              l = @order.transfer_location
              [l.street, l.number, l.complement, l.neighbourhood, city_state(l.city, l.state), l.zip]
            elsif @order.b2c_to_b2b?
              c = b2b_branch
              c && [c.street, c.number, c.complement, c.neighbourhood, city_state(c.city, c.state), c.zip]
            elsif @order.b2c_transfer?
              r = B2bTinyService::B2C_TRANSFER_RECIPIENT
              [r[:endereco], r[:numero], r[:complemento], r[:bairro], city_state(r[:cidade], r[:uf]), r[:cep]]
            end
    Array(parts).compact_blank.join(', ')
  end

  def b2b_branch
    @b2b_branch ||= B2bSetting.current.remessa_issuer(@order)
  end

  def city_state(city, state)
    [city, state].compact_blank.join('/')
  end

  def freight_payer
    return if @order.freight_paid_by.blank?

    @order.shipper? ? 'Remetente' : 'Destinatário'
  end

  def items_table
    # Sem desconto por item: o único desconto é o do pedido, no resumo. Itens antigos que tinham desconto
    # aparecem com o preço já líquido, para a soma bater com o total.
    photos = item_photos
    rows = [['#', 'Foto', 'SKU', 'Produto', 'Qtd.', 'Preço un.', 'Total']]
    @items.each_with_index do |item, index|
      rows << [index + 1, photo_cell(photos[item.sku]), safe(item.sku), safe(item.name.presence || '-'), item.quantity,
               money([item.price.to_f - item.discount.to_f, 0].max), money(item.line_total)]
    end

    pdf.table(rows, header: true, width: pdf.bounds.width,
                    column_widths: { 0 => 22, 1 => PHOTO_SIZE + 8, 2 => 84, 4 => 34, 5 => 68, 6 => 76 },
                    cell_style: { size: 8.5, padding: [6, 5], borders: [:bottom], border_color: LINE, text_color: INK,
                                  valign: :center }) do |t|
      t.row(0).font_style = :bold
      t.row(0).background_color = NAVY
      t.row(0).text_color = 'FFFFFF'
      t.row(0).size = 8
      t.row(0).borders = []
      (1...t.row_length).each { |i| t.row(i).background_color = ZEBRA if i.even? }
      t.column(0).text_color = MUTED
      t.columns(4..6).align = :right
      t.columns(0..1).align = :center
      t.column(1).padding = [4, 4]
      t.column(6).font_style = :bold
    end
    pdf.move_down 12
  end

  # Célula da foto: a miniatura, ou um quadrado claro quando o produto não tem foto (ou ela não veio).
  def photo_cell(data)
    return { content: '', height: PHOTO_SIZE + 8 } unless data

    { image: StringIO.new(data), fit: [PHOTO_SIZE, PHOTO_SIZE], position: :center, vposition: :center }
  end

  # Baixa as fotos dos produtos em paralelo (por SKU). Foto que falhar ou não for JPEG/PNG fica de fora:
  # o romaneio sai mesmo assim.
  def item_photos
    urls = Product.where(sku: @items.map(&:sku).uniq).where.not(image_url: [nil, ''])
                  .pluck(:sku, :image_url).to_h
    return {} if urls.empty?

    queue = Queue.new
    urls.each { |pair| queue << pair }
    photos = Concurrent::Map.new
    Array.new([PHOTO_THREADS, urls.size].min) do
      Thread.new do
        loop do
          sku, url = queue.pop(true)
          data = fetch_photo(url)
          photos[sku] = data if data
        end
      rescue ThreadError
        nil
      end
    end.each(&:join)
    # Registra cada foto no PDF aqui (o Prawn reaproveita na tabela); a que ele não souber ler fica de fora.
    photos.each_pair.to_h.select { |_sku, data| usable_photo?(data) }
  end

  def usable_photo?(data)
    pdf.build_image_object(StringIO.new(data))
    true
  rescue StandardError => e
    Rails.logger.warn "B2bRomaneioPdf foto ilegível: #{e.class} #{e.message}"
    false
  end

  def fetch_photo(url)
    uri = URI(url)
    if uri.host.to_s.end_with?('cdn.shopify.com')
      uri.query = [uri.query, "width=#{PHOTO_WIDTH_PX}"].compact_blank.join('&')
    end
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                                   open_timeout: PHOTO_TIMEOUT, read_timeout: PHOTO_TIMEOUT) do |http|
      http.get(uri.request_uri, 'Accept' => 'image/jpeg,image/png')
    end
    body = response.body.to_s.b
    return unless response.is_a?(Net::HTTPSuccess)
    return unless body.start_with?("\xFF\xD8".b) || body.start_with?("\x89PNG".b)

    body
  rescue StandardError => e
    Rails.logger.warn "B2bRomaneioPdf foto #{url}: #{e.class} #{e.message}"
    nil
  end

  def totals
    quantity = @items.sum { |i| i.quantity.to_i }
    subtotal = @items.sum(&:line_total)
    freight = @order.freight_value.to_f
    discount = @order.discount_amount.to_f

    rows = [['Itens', "#{@items.size} produto(s) · #{quantity} peça(s)"], ['Subtotal', money(subtotal)]]
    rows << ['Desconto', "- #{money(discount)}"] if discount.positive?
    rows << ['Frete', money(freight)] if freight.positive?
    rows << ['Pagamento', @order.payment_description] if @order.payment_label
    total = subtotal - discount + (freight.positive? ? freight : 0)

    box_width = 230
    pdf.bounding_box([pdf.bounds.width - box_width, pdf.cursor], width: box_width) do
      pdf.table(rows, width: box_width, column_widths: [80, 150],
                      cell_style: { size: 9, padding: [4, 8], borders: [], text_color: INK }) do |t|
        t.column(0).text_color = MUTED
        t.column(1).align = :right
      end
      pdf.move_down 4
      pdf.table([['TOTAL', money(total)]], width: box_width, column_widths: [80, 150],
                                            cell_style: { size: 12, font_style: :bold, padding: [8, 8], borders: [],
                                                          background_color: BLUE, text_color: 'FFFFFF' }) do |t|
        t.column(1).align = :right
      end
    end
    pdf.move_down 16
  end

  def notes
    return if @order.notes.blank?

    card_title('Observações')
    pdf.text safe(@order.notes), size: 9, leading: 2
  end

  def footer
    pdf.repeat(:all) do
      pdf.bounding_box([0, -16], width: pdf.bounds.width, height: 20) do
        pdf.stroke_color LINE
        pdf.line_width 0.5
        pdf.stroke_horizontal_line 0, pdf.bounds.width, at: pdf.bounds.top
        pdf.move_down 6
        pdf.fill_color MUTED
        pdf.text "Romaneio ##{@order.id} · documento sem valor fiscal · gerado em #{Time.current.strftime('%d/%m/%Y %H:%M')}", size: 7
      end
    end
    pdf.number_pages 'Página <page> de <total>', at: [pdf.bounds.right - 120, -22], width: 120, align: :right, size: 7, color: MUTED
  end

  def destination_name
    return b2b_branch&.legal_name if @order.b2c_to_b2b?

    @order.sale? ? @order.client&.display_name : @order.transfer_location&.name
  end

  def money(value)
    ActiveSupport::NumberHelper.number_to_currency(value.to_f, unit: 'R$ ', separator: ',', delimiter: '.', format: '%u%n')
  end

  # As fontes embutidas do Prawn só desenham Windows-1252: troca o que não couber (emoji etc.).
  def safe(value)
    value.to_s.encode('Windows-1252', invalid: :replace, undef: :replace, replace: '').encode('UTF-8')
  end
end
