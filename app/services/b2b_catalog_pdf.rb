require 'prawn'
require 'rqrcode'

Prawn::Fonts::AFM.hide_m17n_warning = true

# PDF do catálogo para mandar ao lojista: capa, modelos com as cores (foto, nome, tamanhos disponíveis
# na hora da geração) e, no fim, link + QR code da página onde ele faz a encomenda. Sem preço.
class B2bCatalogPdf
  INK = '111111'.freeze
  MUTED = '767676'.freeze
  MIST = 'F4F4F4'.freeze
  LOW = 'E8590C'.freeze
  LOGO = Rails.root.join('app/assets/images/chase-logo.png').to_s.freeze
  LOGO_WHITE = Rails.root.join('app/assets/images/chase-logo-white.png').to_s.freeze
  IMAGE_TIMEOUT = 8
  COLUMNS = 3

  def initialize(catalog, public_url:)
    @catalog = catalog
    @public_url = public_url
    @images = {}
  end

  def filename
    "catalogo-#{@catalog.title.parameterize}.pdf"
  end

  def render
    pdf = Prawn::Document.new(page_size: 'A4', margin: [36, 36, 42, 36], info: { Title: @catalog.title })
    cover(pdf)
    pdf.start_new_page
    @catalog.styles.each_with_index { |(style, colors), index| style_section(pdf, style, colors, first: index.zero?) }
    closing(pdf)
    footer(pdf)
    pdf.render
  end

  private

  def cover(pdf)
    pdf.fill_color INK
    pdf.fill_rectangle [-36, pdf.bounds.top + 36], pdf.bounds.width + 72, 300
    pdf.fill_color 'FFFFFF'
    pdf.image LOGO_WHITE, at: [0, pdf.bounds.top - 6], height: 26
    pdf.text_box 'CATÁLOGO ATACADO', at: [0, pdf.bounds.top - 120], size: 10, style: :bold, character_spacing: 3
    pdf.text_box @catalog.title.upcase, at: [0, pdf.bounds.top - 140], width: pdf.bounds.width, size: 38, style: :bold, leading: -4
    pdf.fill_color INK
    pdf.move_down 290
    if @catalog.notes.present?
      pdf.text @catalog.notes, size: 12, leading: 3
      pdf.move_down 10
    end
    pdf.fill_color MUTED
    pdf.text "Disponibilidade de #{(@catalog.stock_refreshed_at || Time.current).strftime('%d/%m/%Y %H:%M')}", size: 9
    pdf.text 'Para encomendar, use o link (ou QR code) na última página.', size: 9
    pdf.fill_color INK
  end

  # Os modelos seguem um embaixo do outro; só quebra a página quando a primeira linha de cores não cabe.
  def style_section(pdf, style, colors, first:)
    width = (pdf.bounds.width - 16 * (COLUMNS - 1)) / COLUMNS
    height = width * 1.25
    if pdf.cursor < height + 110
      pdf.start_new_page
    elsif !first
      pdf.move_down 28
    end

    pdf.text style.upcase, size: 20, style: :bold
    pdf.fill_color MUTED
    pdf.text "#{colors.size} cor#{'es' if colors.size > 1}", size: 9
    pdf.fill_color INK
    pdf.move_down 12

    colors.each_slice(COLUMNS) do |row|
      pdf.start_new_page if pdf.cursor < height + 60
      top = pdf.cursor
      row.each_with_index do |color, index|
        pdf.bounding_box([index * (width + 16), top], width: width, height: height + 52) { color_cell(pdf, color, width, height) }
      end
      pdf.move_down 16
    end
  end

  def color_cell(pdf, color, width, height)
    image = image_for(color.main_image)
    if image
      pdf.image StringIO.new(image), fit: [width, height], position: :center
    else
      pdf.fill_color MIST
      pdf.fill_rectangle [0, pdf.cursor], width, height
      pdf.fill_color 'C7C7C7'
      pdf.text_box 'CHASE', at: [0, pdf.cursor - height / 2 + 6], width: width, align: :center, size: 12, style: :bold, character_spacing: 4
      pdf.fill_color INK
      pdf.move_down height
    end
    pdf.move_down 6
    pdf.text color.color_name.presence || '—', size: 10, style: :bold
    sizes = color.variants.map do |v|
      next "<color rgb='BDBDBD'>#{v.size}</color>" if v.sold_out?
      next "<color rgb='#{LOW}'>#{v.size}</color>" if v.low?

      v.size
    end
    pdf.text sizes.join('  '), size: 9, inline_format: true
  end

  def closing(pdf)
    pdf.start_new_page
    pdf.move_down 90
    pdf.image LOGO, height: 30, position: :center
    pdf.move_down 28
    pdf.text 'FAÇA SUA ENCOMENDA', size: 24, style: :bold, align: :center
    pdf.move_down 8
    pdf.fill_color MUTED
    pdf.text 'Aponte a câmera para o QR code ou abra o link abaixo.', size: 11, align: :center
    pdf.fill_color INK
    pdf.move_down 20
    qr = RQRCode::QRCode.new(@public_url).as_png(size: 480, border_modules: 2)
    pdf.image StringIO.new(qr.to_s), width: 220, position: :center
    pdf.move_down 16
    pdf.text @public_url, size: 10, align: :center, color: INK
    pdf.move_down 24
    pdf.fill_color MUTED
    pdf.text 'Tamanhos em laranja: últimas unidades. Em cinza: esgotado no momento.', size: 9, align: :center
    pdf.fill_color INK
  end

  def footer(pdf)
    pdf.repeat(:all) do
      pdf.bounding_box([0, -12], width: pdf.bounds.width, height: 14) do
        pdf.fill_color MUTED
        pdf.text "Chase · #{@catalog.title}", size: 8
        pdf.fill_color INK
      end
    end
    pdf.number_pages '<page>/<total>', at: [pdf.bounds.right - 60, -12], width: 60, align: :right, size: 8, color: MUTED
  end

  # Baixa a foto (Shopify CDN em 600px) e devolve os bytes. Só PNG/JPEG; falha ou formato desconhecido → nil (placeholder).
  def image_for(url)
    return nil if url.blank?
    return @images[url] if @images.key?(url)

    sized = url.include?('cdn.shopify.com') ? "#{url}#{url.include?('?') ? '&' : '?'}width=600" : url
    response = HTTParty.get(sized, timeout: IMAGE_TIMEOUT)
    body = response.body.to_s
    ok = response.code == 200 && (body.start_with?("\x89PNG".b) || body.start_with?("\xFF\xD8".b))
    @images[url] = ok ? body : nil
  rescue StandardError => e
    Rails.logger.error "B2bCatalogPdf image #{url}: #{e.class} #{e.message}"
    @images[url] = nil
  end
end
