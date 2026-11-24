require 'test_helper'
require_relative '../../support/nfe_test_certificate'
require 'minitest/mock'
require_relative '../../support/nfe_schema'

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
    @sale_nature, @transfer_nature = create_natures(@company)
  end

  def create_natures(company)
    [company.operation_natures.create!(description: 'Venda de mercadoria', kind: :sale, cfop: '?102', final_consumer: false,
                                       icms_situation: '102', pis_cst: '49', cofins_cst: '49'),
     company.operation_natures.create!(description: 'Transferência de mercadoria', kind: :transfer, cfop: '?152', final_consumer: false,
                                       icms_situation: '102', pis_cst: '49', cofins_cst: '49')]
  end

  def generate_in(order, environment)
    Nfe::Generator.call(order: order, company: @company, nature: @sale_nature, environment: environment)
  end

  def generate(order, company, nature: nil)
    Nfe::Generator.call(order: order, company: company, nature: nature || (order.sale? ? @sale_nature : @transfer_nature))
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

    note = generate(order, @company)

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
    assert_equal 2, @company.reload.next_nfe_number_homologation
    assert_equal 1, @company.next_nfe_number, "homologação não consome a numeração de produção"

    xml = Nokogiri::XML(note.xml.download)
    assert xml.at_xpath('//n:infNFe', NS)
    assert xml.at_xpath('//ds:Signature', 'ds' => 'http://www.w3.org/2000/09/xmldsig#')
    assert_equal '25405327000174', xml.at_xpath('//n:dest/n:CNPJ', NS).text
  end

  test 'the note keeps the payment method of the order (tPag) for the list; a transfer has none' do
    assert_equal '17', generate(build_order(payment_method: 'pix'), @company).payment_method
    assert_equal '15', Nokogiri::XML(generate(build_order(payment_method: 'boleto'), @company).xml.download).at_xpath('//n:detPag/n:tPag', NS).text

    transfer = generate(build_order(kind: :stock_transfer), @company)
    assert_equal '90', transfer.payment_method
    assert_equal 'Sem pagamento', transfer.payment_label
  end

  test 'the wholesale order discount is prorated over the items (vDesc) and lowers the note total' do
    order = build_order(order_discount: 10, order_discount_type: 'percent') # itens 25,50 -> desconto 2,55

    note = generate(order, @company)

    xml = Nokogiri::XML(note.xml.download)
    item_discounts = xml.xpath('//n:det/n:prod/n:vDesc', NS).map { |n| BigDecimal(n.text) }
    assert_equal BigDecimal('2.55'), item_discounts.sum
    assert_equal BigDecimal('2.55'), BigDecimal(xml.at_xpath('//n:ICMSTot/n:vDesc', NS).text)
    assert_equal BigDecimal('22.95'), note.total_value
  end

  test 'uses the interstate CFOP when the recipient is in another state' do
    @client.update!(state: 'SP', city_ibge_code: '3550308')

    note = generate(build_order, @company)

    assert_equal '6102', note.cfop_summary
  end

  test 'generates a note for a stock transfer using the transfer CFOP, nature and the location as recipient' do
    order = build_order(kind: :stock_transfer)

    note = generate(order, @company)

    assert_equal 'Transferência de mercadoria', note.operation_nature
    assert_equal '5152', note.cfop_summary
    xml = Nokogiri::XML(note.xml.download)
    assert_equal '45723174000110', xml.at_xpath('//n:dest/n:CNPJ', NS).text
    assert_equal '3118601', xml.at_xpath('//n:dest/n:enderDest/n:cMun', NS).text
  end

  test 'the remessa note of a stock transfer goes to CLI CONTAGEM by default, without carrier, apart from the transfer note' do
    @company.update!(tax_regime: 3)
    remessa = @company.operation_natures.create!(description: 'Remessa para depósito fechado ou armazém geral', kind: :other, cfop: '?905',
                                                 final_consumer: false, icms_situation: '41', pis_cst: '08', cofins_cst: '08')
    transfer = @company.operation_natures.create!(description: 'Transferência entre Filiais - MG', kind: :transfer, cfop: '?152', final_consumer: false,
                                                  icms_situation: '41', pis_cst: '08', cofins_cst: '08')
    carrier = Carrier.create!(name: 'Mix Cargo', registration: '13.642.117/0001-10', street: 'Rua A', number: '1', neighbourhood: 'Centro',
                              city: 'Belo Horizonte', state: 'MG', zip: '30000-000')
    order = build_order(kind: :stock_transfer)
    order.update_columns(nf_carrier_id: carrier.id, nf_additional_info: 'Só da nota de transferência')

    principal = Nfe::Generator.call(order: order, company: @company, nature: transfer, environment: 'producao')
    note = Nfe::Generator.call(order: order, company: @company, nature: remessa, environment: 'producao', role: 'remessa')

    assert_nil principal.role
    assert note.remessa?
    assert_equal '5905', note.cfop_summary
    xml = Nokogiri::XML(note.xml.download)
    assert_equal 'CLI CONTAGEM', xml.at_xpath('//n:dest/n:xNome', NS).text
    assert_equal '34028316900520', xml.at_xpath('//n:dest/n:CNPJ', NS).text
    assert_equal '0620144620013', xml.at_xpath('//n:dest/n:IE', NS).text
    assert_equal '3118601', xml.at_xpath('//n:dest/n:enderDest/n:cMun', NS).text
    assert_equal '9', xml.at_xpath('//n:transp/n:modFrete', NS).text
    assert_nil xml.at_xpath('//n:transp/n:transporta', NS)
    assert_no_match(/Só da nota de transferência/, xml.at_xpath('//n:infAdic/n:infCpl', NS)&.text.to_s)
    assert_equal [], NfeSchema.errors(note.xml.download)

    error = assert_raises(Nfe::Generator::Error) { Nfe::Generator.call(order: order, company: @company, nature: remessa, environment: 'producao', role: 'remessa') }
    assert_match(/nota de remessa de produção ativa/, error.message)
  end

  test 'the remessa recipient changed only on the order goes into its note' do
    remessa = @company.operation_natures.create!(description: 'Remessa para depósito', kind: :other, cfop: '?905', final_consumer: false,
                                                 icms_situation: '102', pis_cst: '49', cofins_cst: '49')
    order = build_order(kind: :stock_transfer)
    order.update_columns(remessa_recipient: B2bSetting.normalize_recipient(
      'name' => 'Armazém SP', 'document' => '45.723.174/0001-10', 'state_registration' => '', 'street' => 'Rua X', 'number' => '5',
      'neighbourhood' => 'Centro', 'city' => 'São Paulo', 'state' => 'sp', 'zip' => '01001-000', 'city_ibge_code' => '3550308'
    ))

    xml = Nokogiri::XML(Nfe::Generator.call(order: order, company: @company, nature: remessa, environment: 'producao', role: 'remessa').xml.download)

    assert_equal 'Armazém SP', xml.at_xpath('//n:dest/n:xNome', NS).text
    assert_equal 'SP', xml.at_xpath('//n:dest/n:enderDest/n:UF', NS).text
    assert_equal '6905', xml.at_xpath('//n:det/n:prod/n:CFOP', NS).text
    assert_equal B2bSetting::REMESSA_DEFAULT_RECIPIENT['name'], B2bSetting.current.remessa_recipient_data['name']
  end

  test 'the unit price is the price minus the item discount' do
    order = build_order(items: [['SKU-1', 2, 10, 1.5]])

    note = generate(order, @company)

    assert_equal BigDecimal('17.00'), note.total_value
    assert_equal '8.5000', Nokogiri::XML(note.xml.download).at_xpath('//n:det/n:prod/n:vUnCom', NS).text
  end

  test 'product commercial unit and CEST come from the product' do
    note = generate(build_order, @company)

    second = Nokogiri::XML(note.xml.download).xpath('//n:det', NS)[1]
    assert_equal 'PC', second.at_xpath('n:prod/n:uCom', NS).text
    assert_equal '2806100', second.at_xpath('n:prod/n:CEST', NS).text
  end

  test 'missing fiscal data raises one error listing everything, creates no note and keeps the number' do
    Product.find_by(sku: 'SKU-2').update!(ncm: nil)
    @client.update!(city_ibge_code: nil)
    order = build_order

    error = Nfe::Ibge.stub(:lookup, nil) { assert_raises(Nfe::Generator::Error) { generate(order, @company) } }

    assert_match(/NCM do SKU SKU-2/, error.message)
    assert_match(/código IBGE do destinatário/i, error.message)
    assert_equal 0, FiscalNote.count
    assert_equal 1, @company.reload.next_nfe_number
  end

  test 'a recipient without the IBGE code gets it from the CEP and the registration keeps it' do
    @location.update!(city_ibge_code: nil)
    order = build_order(kind: :stock_transfer)
    looked_up = []
    lookup = ->(zip) { looked_up << zip; { ibge: '3118601', city: 'Contagem', state: 'MG' } }

    note = Nfe::Ibge.stub(:lookup, lookup) { generate(order, @company) }

    assert_equal ['32000-000'], looked_up
    assert_equal '3118601', Nokogiri::XML(note.xml.download).at_xpath('//n:dest/n:enderDest/n:cMun', NS).text
    assert_equal '3118601', @location.reload.city_ibge_code
  end

  test 'names with stray spaces (like the store registrations) go trimmed and the note passes the schema' do
    @location.update!(name: 'Barra Shopping ', street: ' Avenida das Américas ', complement: 'Loja  244 ')

    note = Nfe::Generator.call(order: build_order(kind: :stock_transfer), company: @company, nature: @transfer_nature, environment: 'producao')

    xml = note.xml.download
    assert_equal 'Barra Shopping', Nokogiri::XML(xml).at_xpath('//n:dest/n:xNome', NS).text
    assert_equal 'Loja 244', Nokogiri::XML(xml).at_xpath('//n:dest/n:enderDest/n:xCpl', NS).text
    assert_equal [], NfeSchema.errors(xml)
  end

  test 'the note details of the order go into the note: carrier (transporta), freight mode and additional info' do
    carrier = Carrier.create!(name: 'Mix Cargo', registration: '13.642.117/0001-10', state_registration: '062.123.456/0001',
                              street: 'Rua Noraldino Lima', number: '580', neighbourhood: 'Centro', city: 'Belo Horizonte', state: 'MG', zip: '30000-000')
    order = build_order(kind: :stock_transfer)
    order.update_columns(nf_carrier_id: carrier.id, nf_additional_info: 'Pedido 89 - conferir volumes na entrega')

    note = Nfe::Generator.call(order: order, company: @company, nature: @transfer_nature, environment: 'producao')

    xml = Nokogiri::XML(note.xml.download)
    assert_equal '0', xml.at_xpath('//n:transp/n:modFrete', NS).text
    assert_equal '13642117000110', xml.at_xpath('//n:transp/n:transporta/n:CNPJ', NS).text
    assert_equal 'Mix Cargo', xml.at_xpath('//n:transp/n:transporta/n:xNome', NS).text
    assert_equal '0621234560001', xml.at_xpath('//n:transp/n:transporta/n:IE', NS).text
    assert_equal 'Rua Noraldino Lima, 580', xml.at_xpath('//n:transp/n:transporta/n:xEnder', NS).text
    assert_equal 'Pedido 89 - conferir volumes na entrega', xml.at_xpath('//n:infAdic/n:infCpl', NS).text
    assert_equal [], NfeSchema.errors(note.xml.download)
  end

  test 'without note details an order outside the Log02 has no carrier and no freight' do
    order = build_order(kind: :stock_transfer, tiny_reference_id: '123')
    xml = Nokogiri::XML(generate(order, @company).xml.download)
    assert_equal '9', xml.at_xpath('//n:transp/n:modFrete', NS).text
    assert_nil xml.at_xpath('//n:transp/n:transporta', NS)
    assert_nil xml.at_xpath('//n:prod/n:xPed', NS)
  end

  # O Correios Log recusa o XML sem transporta (400 sem corpo) e confere o xPed na nota que abre pela chave
  # (NF-e 15788 do pedido 93).
  test 'a Log02 order without a carrier goes with the ECT head office in transporta and its Correios number in xPed' do
    [build_order(kind: :stock_transfer, correios_order_id: 25_370_767), build_order(kind: :b2c_transfer, correios_order_id: 25_388_909),
     build_order(kind: :sale, freight_service: 'SEDEX CORREIOS LOG+', freight_value: 100, correios_order_id: 25_402_497)].each do |order|
      raw = generate(order, @company).xml.download
      assert_equal [], NfeSchema.errors(raw)
      xml = Nokogiri::XML(raw)
      assert_equal '0', xml.at_xpath('//n:transp/n:modFrete', NS).text
      assert_equal '34028316000103', xml.at_xpath('//n:transp/n:transporta/n:CNPJ', NS).text
      assert_equal 'EMPRESA BRASILEIRA DE CORREIOS E TELEGRAFOS', xml.at_xpath('//n:transp/n:transporta/n:xNome', NS).text
      assert_equal [order.correios_order_id.to_s] * order.b2b_order_items.size, xml.xpath('//n:det/n:prod/n:xPed', NS).map(&:text)
      assert_equal 'indTot', xml.at_xpath('//n:prod/n:xPed', NS).previous_element.name
    end
  end

  test 'the chosen no-freight mode leaves the carrier out' do
    order = build_order(kind: :stock_transfer, nf_freight_mode: '9')
    xml = Nokogiri::XML(generate(order, @company).xml.download)
    assert_equal '9', xml.at_xpath('//n:transp/n:modFrete', NS).text
    assert_nil xml.at_xpath('//n:transp/n:transporta', NS)
  end

  test 'a stock transfer note carries the IBS/CBS group of non-incidence (SEFAZ rejects 1115 without it)' do
    @company.update!(tax_regime: 3)
    nature = @company.operation_natures.create!(description: 'Transferência entre Filiais - MG', kind: :transfer, cfop: '?152', final_consumer: false,
                                                icms_situation: '00', icms_rate: 18, pis_cst: '01', pis_rate: 1.65, cofins_cst: '01', cofins_rate: 7.6)
    note = Nfe::Generator.call(order: build_order(kind: :stock_transfer), company: @company, nature: nature, environment: 'producao')

    xml = Nokogiri::XML(note.xml.download)
    assert_equal 2, xml.xpath('//n:det/n:imposto/n:IBSCBS', NS).size
    assert xml.at_xpath('//n:det/n:imposto/n:IBSCBS/n:CST', NS).text.present?
    assert_equal [], NfeSchema.errors(note.xml.download)
  end

  test 'a SKU that is not a product is reported' do
    error = assert_raises(Nfe::Generator::Error) do
      generate(build_order(items: [['NAO-EXISTE', 1, 10, 0]]), @company)
    end

    assert_match(/NAO-EXISTE/, error.message)
  end

  test 'a second note of the same environment is blocked while the first is active; a rejected one gives its number back' do
    order = build_order
    first = generate(order, @company)

    error = assert_raises(Nfe::Generator::Error) { generate(order, @company) }
    assert_match(/nota fiscal de .* ativa/i, error.message)
    assert_equal 1, FiscalNote.count

    first.update!(status: :erro)
    error = assert_raises(Nfe::Generator::Error) { generate(order, @company.reload) }
    assert_match(/sem resposta da SEFAZ/, error.message, 'sem resposta: consultar antes de emitir outra')

    first.update!(status: :rejeitada, sefaz_status_code: '225')
    second = generate(order, @company.reload)
    assert_equal first.id, second.id
    assert_equal 1, second.number
    assert second.assinada?
  end

  test 'the same order can have one note in homologação and one in produção' do
    order = build_order
    test_note = generate_in(order, 'homologacao')
    real_note = generate_in(order, 'producao')

    assert test_note.homologacao?
    assert real_note.producao?
  end

  test 'a company without a valid certificate cannot issue' do
    company = Company.create!(
      legal_name: 'Sem Certificado', cnpj: '45723174000110', tax_regime: 1, street: 'Rua', number: '1',
      neighbourhood: 'B', city: 'BH', city_ibge_code: '3106200', state: 'MG', zip: '30000000'
    )

    error = assert_raises(Nfe::Generator::Error) { generate(build_order, company) }

    assert_match(/certificado/i, error.message)
  end

  test 'a failure while building rolls back so the number is not consumed' do
    @sale_nature.update_column(:icms_situation, '500')

    assert_raises(Nfe::Generator::Error) { generate(build_order, @company.reload) }

    assert_equal 0, FiscalNote.count
    assert_equal 1, @company.reload.next_nfe_number
  end
end
