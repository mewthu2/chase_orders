require 'test_helper'
require_relative '../../support/shopify_order_factory'
require_relative '../../support/nfe_company_factory'
require_relative '../../support/nfe_schema'

class Nfe::ShopifyGeneratorTest < ActiveSupport::TestCase
  include NfeCompanyFactory
  NS = { 'n' => 'http://www.portalfiscal.inf.br/nfe' }.freeze

  def setup
    @company = create_nfe_company
    @nature = create_sale_nature(@company)
    Product.create!(sku: 'SKU-1', shopify_product_name: 'Camiseta', ncm: '61091000')
    Product.create!(sku: 'SKU-2', shopify_product_name: 'Short', ncm: '62034200')
    @shopify_order = Nfe::ShopifyOrder.new(ShopifyOrderFactory.node)
    @recipient = { name: 'Maria Cliente', document: '529.982.247-25', ie_indicator: '9', street: 'Rua das Flores',
                   number: '10', neighbourhood: 'Centro', city: 'São Paulo', city_ibge_code: '3550308', state: 'SP',
                   zip: '01001-000', email: 'maria@example.com' }
  end

  def generate(recipient: @recipient, nature: @nature)
    Nfe::ShopifyGenerator.call(company: @company, nature: nature, shopify_order: @shopify_order, recipient: recipient,
                               payment: { method: '03', installments: 3, description: 'cartão' }, freight_mode: '0')
  end

  test 'generates a signed final consumer note with the nature rules and consumes the homologation number' do
    note = generate
    xml = Nokogiri::XML(note.xml.download)

    assert note.assinada?
    assert_equal '#1001', note.shopify_order_name
    assert_equal @nature, note.nature
    assert_equal 'Venda Online', note.operation_nature
    assert_equal '6108', note.cfop_summary # não contribuinte de outra UF
    assert_equal BigDecimal('245'), note.total_value
    assert_equal '15.00', xml.at_xpath('//n:ICMSTot/n:vFrete', NS).text
    # Frete rateado pelo valor líquido: 180/230 e 50/230 de 15.
    assert_equal %w[11.74 3.26], xml.xpath('//n:det/n:prod/n:vFrete', NS).map(&:text)
    assert_equal '245.00', xml.at_xpath('//n:pag/n:detPag/n:vPag', NS).text
    assert_match(/Pedido #1001/, xml.at_xpath('//n:infCpl', NS).text)
    assert_equal [], NfeSchema.errors(note.xml.download)
    assert_equal 2, @company.reload.next_nfe_number_homologation
    assert_equal 1, @company.next_nfe_number
  end

  test 'in-state sale uses 5102' do
    note = generate(recipient: @recipient.merge(state: 'MG', city: 'Belo Horizonte', city_ibge_code: '3106200'))
    assert_equal '5102', note.cfop_summary
  end

  test 'a rejected note gives its number back to the next attempt' do
    first = generate
    first.update!(status: :rejeitada, sefaz_status_code: '225', error_message: 'Rejeição 225')

    second = generate
    assert_equal first.id, second.id
    assert_equal first.number, second.number
    assert second.assinada?
    assert_equal 2, @company.reload.next_nfe_number_homologation
  end

  test 'denied notes keep their number burnt' do
    first = generate
    first.update!(status: :rejeitada, sefaz_status_code: '302')

    second = generate
    refute_equal first.id, second.id
    assert_equal first.number + 1, second.number
  end

  test 'blocks a second note while the first is active or without SEFAZ answer' do
    note = generate
    error = assert_raises(Nfe::ShopifyGenerator::Error) { generate }
    assert_match(/ativa/, error.message)

    note.update!(status: :erro)
    error = assert_raises(Nfe::ShopifyGenerator::Error) { generate }
    assert_match(/Consulte/, error.message)
  end

  test 'a note authorized in homologation does not block the real note in production' do
    generate.update!(status: :autorizada)
    @company.update_column(:environment, Company.environments[:producao])

    note = generate
    assert note.producao?
  end

  test 'lists every missing fiscal data at once' do
    Product.find_by(sku: 'SKU-2').update!(ncm: nil)
    error = assert_raises(Nfe::ShopifyGenerator::Error) do
      generate(recipient: @recipient.merge(document: '123', city_ibge_code: ''))
    end
    assert_match(/NCM do SKU SKU-2/, error.message)
    assert_match(/CPF\/CNPJ válido/, error.message)
    assert_match(/código IBGE/, error.message)
    assert_equal 0, FiscalNote.count
  end

  test 'refuses a nature from another company' do
    other = create_nfe_company(cnpj: '45.723.174/0001-10', legal_name: 'Outra')
    error = assert_raises(Nfe::ShopifyGenerator::Error) { generate(nature: create_sale_nature(other)) }
    assert_match(/natureza/, error.message)
  end
end
