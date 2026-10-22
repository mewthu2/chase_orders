require 'test_helper'
require_relative '../../support/nfe_test_certificate'

class Nfe::GeneratorTest < ActiveSupport::TestCase
  NS = { 'n' => 'http://www.portalfiscal.inf.br/nfe' }.freeze

  def setup
    @user = User.create!(name: 'Gerador', email: 'gerador@example.com', password: 'password123')
    @company = create_company
    @client = Client.create!(
      responsible_name: 'Fulano', business_name: 'Cliente Atacado Ltda', registration: '25.405.327/0001-74',
      state_registration: '111222333', ie_indicator: 1, street: 'Rua B', number: '20', neighbourhood: 'Bairro',
      city: 'Belo Horizonte', state: 'MG', zip: '31000-000', city_ibge_code: '3106200', email: 'c@example.com'
    )
    @location = TransferLocation.create!(
      name: 'CD Destino', registration: '45.723.174/0001-10', state_registration: '444555666', street: 'Rua C',
      number: '30', neighbourhood: 'Distrito', city: 'Contagem', state: 'MG', zip: '32000-000', city_ibge_code: '3118601'
    )
    Product.create!(sku: 'SKU-1', shopify_product_name: 'Camiseta', ncm: '61091000')
    Product.create!(sku: 'SKU-2', shopify_product_name: 'Calça', ncm: '62034200', cest: '2806100', commercial_unit: 'PC')
  end

  def create_company(overrides = {})
    file = Tempfile.new(['cert', '.pfx'], binmode: true)
    file.write(NfeTestCertificate.pfx)
    file.rewind
    Company.create!({
      legal_name: 'Empresa Emissora Ltda', cnpj: '11.222.333/0001-81', state_registration: '123456789', tax_regime: 1,
      street: 'Rua A', number: '10', neighbourhood: 'Centro', city: 'Belo Horizonte', city_ibge_code: '3106200',
      state: 'MG', zip: '30000-000', certificate_file: Rack::Test::UploadedFile.new(file.path, 'application/x-pkcs12'),
      certificate_password: 'senha123'
    }.merge(overrides))
  end

  def build_order(kind: :sale, items: [['SKU-1', 2, 10, 0], ['SKU-2', 1, 5.5, 0]], **attrs)
    order = B2bOrder.new({ kind: kind, user: @user }.merge(kind == :sale ? { client: @client } : { transfer_location: @location, price_list: :transfer, receiver_name: 'Maria' }).merge(attrs))
    items.each { |sku, quantity, price, discount| order.b2b_order_items.build(sku: sku, name: sku, quantity: quantity, price: price, discount: discount) }
    order.save!
    order
  end

  test 'generates a signed note for a wholesale order and consumes the number' do
    order = build_order

    note = Nfe::Generator.call(order: order, company: @company)

    assert note.persisted?
    assert note.assinada?
    assert_equal order, note.b2b_order
    assert_equal 1, note.number
    assert_equal 1, note.series
    assert_equal 44, note.access_key.length
    assert_equal BigDecimal('25.50'), note.total_value
    assert_equal 'Venda de mercadoria', note.operation_nature
    assert_equal '5102', note.cfop_summary
    assert note.homologacao?
    assert_equal 2, @company.reload.next_nfe_number

    xml = Nokogiri::XML(note.xml.download)
    assert xml.at_xpath('//n:infNFe', NS)
    assert xml.at_xpath('//ds:Signature', 'ds' => 'http://www.w3.org/2000/09/xmldsig#')
    assert_equal '25405327000174', xml.at_xpath('//n:dest/n:CNPJ', NS).text
  end

  test 'uses the interstate CFOP when the recipient is in another state' do
    @client.update!(state: 'SP', city_ibge_code: '3550308')

    note = Nfe::Generator.call(order: build_order, company: @company)

    assert_equal '6102', note.cfop_summary
  end

  test 'generates a note for a stock transfer using the transfer CFOP, nature and the location as recipient' do
    order = build_order(kind: :stock_transfer)

    note = Nfe::Generator.call(order: order, company: @company)

    assert_equal 'Transferência de mercadoria', note.operation_nature
    assert_equal '5152', note.cfop_summary
    xml = Nokogiri::XML(note.xml.download)
    assert_equal '45723174000110', xml.at_xpath('//n:dest/n:CNPJ', NS).text
    assert_equal '3118601', xml.at_xpath('//n:dest/n:enderDest/n:cMun', NS).text
  end

  test 'the unit price is the price minus the item discount' do
    order = build_order(items: [['SKU-1', 2, 10, 1.5]])

    note = Nfe::Generator.call(order: order, company: @company)

    assert_equal BigDecimal('17.00'), note.total_value
    assert_equal '8.5000', Nokogiri::XML(note.xml.download).at_xpath('//n:det/n:prod/n:vUnCom', NS).text
  end

  test 'product commercial unit and CEST come from the product' do
    note = Nfe::Generator.call(order: build_order, company: @company)

    second = Nokogiri::XML(note.xml.download).xpath('//n:det', NS)[1]
    assert_equal 'PC', second.at_xpath('n:prod/n:uCom', NS).text
    assert_equal '2806100', second.at_xpath('n:prod/n:CEST', NS).text
  end

  test 'missing fiscal data raises one error listing everything, creates no note and keeps the number' do
    Product.find_by(sku: 'SKU-2').update!(ncm: nil)
    @client.update!(city_ibge_code: nil)
    order = build_order

    error = assert_raises(Nfe::Generator::Error) { Nfe::Generator.call(order: order, company: @company) }

    assert_match(/NCM do SKU SKU-2/, error.message)
    assert_match(/código IBGE do destinatário/i, error.message)
    assert_equal 0, FiscalNote.count
    assert_equal 1, @company.reload.next_nfe_number
  end

  test 'a SKU that is not a product is reported' do
    error = assert_raises(Nfe::Generator::Error) do
      Nfe::Generator.call(order: build_order(items: [['NAO-EXISTE', 1, 10, 0]]), company: @company)
    end

    assert_match(/NAO-EXISTE/, error.message)
  end

  test 'a second note for the same order is blocked while the first is active, then allowed after an error' do
    order = build_order
    first = Nfe::Generator.call(order: order, company: @company)

    error = assert_raises(Nfe::Generator::Error) { Nfe::Generator.call(order: order, company: @company) }
    assert_match(/nota fiscal ativa/i, error.message)
    assert_equal 1, FiscalNote.count

    first.update!(status: :erro)
    second = Nfe::Generator.call(order: order, company: @company.reload)
    assert_equal 2, second.number
  end

  test 'a company without a valid certificate cannot issue' do
    company = Company.create!(
      legal_name: 'Sem Certificado', cnpj: '45723174000110', tax_regime: 1, street: 'Rua', number: '1',
      neighbourhood: 'B', city: 'BH', city_ibge_code: '3106200', state: 'MG', zip: '30000000'
    )

    error = assert_raises(Nfe::Generator::Error) { Nfe::Generator.call(order: build_order, company: company) }

    assert_match(/certificado/i, error.message)
  end

  test 'a failure while building rolls back so the number is not consumed' do
    @company.update_column(:icms_situation, '500')

    assert_raises(Nfe::Generator::Error) { Nfe::Generator.call(order: build_order, company: @company.reload) }

    assert_equal 0, FiscalNote.count
    assert_equal 1, @company.reload.next_nfe_number
  end
end
