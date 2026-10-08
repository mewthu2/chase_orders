require 'test_helper'
require 'webmock/minitest'

class B2bCatalogPdfTest < ActiveSupport::TestCase
  def setup
    user = User.create!(name: 'PDF', email: 'pdf_catalog@example.com', password: 'password123')
    Product.create!(sku: 'A-P', shopify_product_name: 'Top A Black', option1: 'P')
    Product.create!(sku: 'A-M', shopify_product_name: 'Top A Black', option1: 'M')
    @catalog = B2bCatalog.create!(title: 'Coleção Verão', notes: 'Até sexta', user: user,
                                  products_attributes: [{ style_name: 'Top Aurora', color_name: 'Black', skus: %w[A-P A-M] }])
    @catalog.products.first.update!(image_urls: ['https://cdn.example.com/a.png'])
    @catalog.variants.first.update!(available: 3, availability: :low)
  end

  # O Prawn grava o texto em hexadecimal (WinAnsi), quebrado pelo kerning: junta os pedaços de cada TJ.
  def pdf_text(body)
    body.scan(/\[(.*?)\] TJ/m).map do |(array)|
      array.scan(/<([0-9a-f]+)>/).map { |(hex)| [hex].pack('H*').force_encoding('Windows-1252').encode('UTF-8') }.join
    end.join("\n")
  end

  test 'renders a PDF with the styles, colors and sizes, without prices' do
    png = File.binread(Rails.root.join('test/fixtures/files/tiny.png'))
    stub_request(:get, /cdn\.example\.com/).to_return(status: 200, body: png, headers: { 'Content-Type' => 'image/png' })

    pdf = B2bCatalogPdf.new(@catalog, public_url: 'https://honey.example.com/catalogo/abc')
    body = pdf.render

    text = pdf_text(body)

    assert body.start_with?('%PDF')
    assert_includes text, 'TOP AURORA'
    assert_includes text, 'Black'
    assert_includes text, 'COLEÇÃO VERÃO'
    refute_includes text, 'R$'
    assert_equal 'catalogo-colecao-verao.pdf', pdf.filename
  end

  test 'a broken image becomes a placeholder instead of failing, and the Chase logo is still there' do
    stub_request(:get, /cdn\.example\.com/).to_return(status: 500)

    body = B2bCatalogPdf.new(@catalog, public_url: 'https://x/catalogo/abc').render
    assert body.start_with?('%PDF')
    # logo branco na capa + logo escuro na página do QR code (cada PNG com transparência vira imagem +
    # máscara) + o QR code
    assert_equal 5, body.scan('/Subtype /Image').size
  end
end
