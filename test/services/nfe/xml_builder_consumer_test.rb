require 'test_helper'
require_relative '../../support/nfe_test_certificate'
require_relative '../../support/nfe_schema'

# Venda ao consumidor final pela internet, Regime Normal, com ICMS, DIFAL, PIS e COFINS.
class Nfe::XmlBuilderConsumerTest < ActiveSupport::TestCase
  NS = { 'n' => 'http://www.portalfiscal.inf.br/nfe' }.freeze

  def company(overrides = {})
    Company.new({
      legal_name: 'Chase Brasil Comercio Ltda', cnpj: '11222333000181', state_registration: '0029090240268',
      tax_regime: 3, street: 'Av. Raja Gabaglia', number: '4343', neighbourhood: 'Santa Lucia', city: 'Belo Horizonte',
      city_ibge_code: '3106200', state: 'MG', zip: '30350-577', phone: '(11) 93054-1289',
      email: 'fiscal@example.com', environment: :homologacao
    }.merge(overrides))
  end

  def nature(overrides = {})
    OperationNature.new({ company: company, description: 'Venda Online', cfop: '?102', icms_situation: '00',
                          icms_rate: 18, difal: true, pis_cst: '01', pis_rate: 1.65, cofins_cst: '01', cofins_rate: 7.6 }
                        .merge(overrides)).tap(&:valid?)
  end

  def recipient(overrides = {})
    { name: 'Maria Cliente', document: '52998224725', ie_indicator: 9, street: 'Rua das Flores', number: '10',
      neighbourhood: 'Centro', city: 'São Paulo', city_ibge_code: '3550308', state: 'SP', zip: '01001000',
      email: 'maria@example.com' }.merge(overrides)
  end

  def items(cfop)
    [
      { code: 'SKU-1', description: 'Camiseta', ncm: '61091000', origin: 0, unit: 'UN', quantity: 2,
        unit_price: '100.00', discount: '20.00', freight: '10.00', cfop: cfop },
      { code: 'SKU-2', description: 'Short', ncm: '62034200', origin: 0, unit: 'UN', quantity: 1,
        unit_price: '50.00', discount: '0', freight: '5.00', cfop: cfop }
    ]
  end

  def build(recipient: self.recipient, nature: self.nature, company: self.company, cfop: '6102')
    Nfe::XmlBuilder.new(
      company: company, recipient: recipient, items: items(cfop), number: 7, series: 1, operation_nature: nature.description,
      issued_at: Time.utc(2026, 10, 28, 15), cnf: '12345678', final_consumer: true, presence: '2', freight_mode: '0',
      tax: nature.tax_rules, payments: [{ method: '03', installments: 3, amount: '195.00' }],
      additional_info: 'Pedido #1001 (loja virtual)', fisco_info: 'Info fisco'
    ).call
  end

  def doc(result)
    Nokogiri::XML(result.xml)
  end

  def signed(result)
    Nfe::Signer.new(Nfe::Certificate.new(NfeTestCertificate.pfx, 'senha123')).sign(result.xml)
  end

  test 'interstate sale to a final consumer is valid against the official schema' do
    result = build
    assert_equal [], NfeSchema.errors(signed(result))
  end

  test 'in-state sale to a final consumer is valid against the official schema' do
    result = build(recipient: recipient(state: 'MG', city: 'Belo Horizonte', city_ibge_code: '3106200'), cfop: '5102')
    assert_equal [], NfeSchema.errors(signed(result))
  end

  test 'final consumer over the internet with no intermediary' do
    ide = doc(build).at_xpath('//n:ide', NS)
    assert_equal '1', ide.at_xpath('n:indFinal', NS).text
    assert_equal '2', ide.at_xpath('n:indPres', NS).text
    assert_equal '0', ide.at_xpath('n:indIntermed', NS).text
    assert_equal '2', ide.at_xpath('n:idDest', NS).text
    assert_equal '52998224725', doc(build).at_xpath('//n:dest/n:CPF', NS).text
    assert_equal '9', doc(build).at_xpath('//n:dest/n:indIEDest', NS).text
  end

  test 'interstate ICMS from MG to SP (both Southeast) is 12%' do
    det = doc(build).at_xpath('//n:det[@nItem="1"]', NS)
    icms = det.at_xpath('n:imposto/n:ICMS/n:ICMS00', NS)
    # base = 200 - 20 + 10 = 190
    assert_equal '190.00', icms.at_xpath('n:vBC', NS).text
    assert_equal '12.0000', icms.at_xpath('n:pICMS', NS).text
    assert_equal '22.80', icms.at_xpath('n:vICMS', NS).text
  end

  # Nota 33363 emitida pelo Tiny para o RS (27/10/2026): mesmos itens, frete e alíquotas, mesmos centavos.
  test 'reproduces the DIFAL (base dupla) and IBS/CBS of a note issued by Tiny' do
    tiny_nature = nature(pis_rate: 0.65, cofins_rate: 3, exclude_icms_from_pis_cofins_base: false, uf_rates: { 'RS' => { 'internal' => '17', 'fcp' => '2' } })
    tiny_items = [
      { code: 'TOP-1250-P', description: 'Top', ncm: '61046300', origin: 0, quantity: 1, unit_price: '389.00', freight: '12.30', cfop: '6102' },
      { code: 'TOP-1251-P', description: 'Top', ncm: '61046300', origin: 0, quantity: 1, unit_price: '449.00', freight: '14.20', cfop: '6102' }
    ]
    result = Nfe::XmlBuilder.new(
      company: company, recipient: recipient(state: 'RS', city: 'Porto Alegre', city_ibge_code: '4314902'),
      items: tiny_items, number: 7, series: 1, operation_nature: 'Venda Online', issued_at: Time.utc(2026, 10, 27, 11),
      cnf: '12345678', final_consumer: true, presence: '2', freight_mode: '0', tax: tiny_nature.tax_rules,
      payments: [{ method: '99', description: 'Conta a receber', amount: '864.50' }]
    ).call
    xml = doc(result)
    item = ->(path) { xml.at_xpath("//n:det[@nItem=\"1\"]/n:imposto/#{path}", NS).text }

    assert_equal '48.16', item['n:ICMS/n:ICMS00/n:vICMS']
    assert_equal '2.61', item['n:PIS/n:PISAliq/n:vPIS']
    assert_equal '12.04', item['n:COFINS/n:COFINSAliq/n:vCOFINS']
    assert_equal '495.43', item['n:ICMSUFDest/n:vBCUFDest']
    assert_equal '9.91', item['n:ICMSUFDest/n:vFCPUFDest']
    assert_equal '36.07', item['n:ICMSUFDest/n:vICMSUFDest']
    assert_equal '292.51', item['n:IBSCBS/n:gIBSCBS/n:vBC']
    assert_equal '0.29', item['n:IBSCBS/n:gIBSCBS/n:gIBSUF/n:vIBSUF']
    assert_equal '2.63', item['n:IBSCBS/n:gIBSCBS/n:gCBS/n:vCBS']

    total = ->(path) { xml.at_xpath("//n:total/#{path}", NS).text }
    assert_equal '103.74', total['n:ICMSTot/n:vICMS']
    assert_equal '21.35', total['n:ICMSTot/n:vFCPUFDest']
    assert_equal '77.70', total['n:ICMSTot/n:vICMSUFDest']
    assert_equal '5.62', total['n:ICMSTot/n:vPIS']
    assert_equal '25.94', total['n:ICMSTot/n:vCOFINS']
    assert_equal '864.50', total['n:ICMSTot/n:vNF']
    assert_equal '630.15', total['n:IBSCBSTot/n:vBCIBSCBS']
    assert_equal '0.63', total['n:IBSCBSTot/n:gIBS/n:vIBS']
    assert_equal '5.67', total['n:IBSCBSTot/n:gCBS/n:vCBS']
    assert_equal '864.50', total['n:vNFTot']
    assert_equal [], NfeSchema.errors(signed(result))
  end

  test 'FCP of the destination is added and Northeast destinations use 7%' do
    result = build(recipient: recipient(state: 'RJ', city: 'Rio de Janeiro', city_ibge_code: '3304557'))
    det = doc(result).at_xpath('//n:det[@nItem="2"]', NS) # base = 50 + 5 = 55
    assert_equal '12.0000', det.at_xpath('n:imposto/n:ICMS/n:ICMS00/n:pICMS', NS).text # RJ é Sudeste: 12%
    # base dupla: 55 / (1 - 22%) = 70.51
    assert_equal '70.51', det.at_xpath('n:imposto/n:ICMSUFDest/n:vBCUFDest', NS).text
    assert_equal '1.41', det.at_xpath('n:imposto/n:ICMSUFDest/n:vFCPUFDest', NS).text # FCP RJ 2%
    assert_equal '7.50', det.at_xpath('n:imposto/n:ICMSUFDest/n:vICMSUFDest', NS).text # 70.51 * 20% - 55 * 12%

    result = build(recipient: recipient(state: 'BA', city: 'Salvador', city_ibge_code: '2927408'))
    assert_equal '7.0000', doc(result).at_xpath('//n:det[@nItem="2"]//n:ICMS00/n:pICMS', NS).text
  end

  test 'in-state sale uses the internal rate and has no DIFAL' do
    result = build(recipient: recipient(state: 'MG', city: 'Belo Horizonte', city_ibge_code: '3106200'), cfop: '5102')
    assert_equal '18.0000', doc(result).at_xpath('//n:det[@nItem="1"]//n:ICMS00/n:pICMS', NS).text
    assert_nil doc(result).at_xpath('//n:ICMSUFDest', NS)
    assert_nil doc(result).at_xpath('//n:ICMSTot/n:vICMSUFDest', NS)
  end

  test 'PIS and COFINS are charged on the base without ICMS' do
    det = doc(build).at_xpath('//n:det[@nItem="1"]/n:imposto', NS)
    # 190 - 22.80 = 167.20
    assert_equal '167.20', det.at_xpath('n:PIS/n:PISAliq/n:vBC', NS).text
    assert_equal '2.76', det.at_xpath('n:PIS/n:PISAliq/n:vPIS', NS).text
    assert_equal '12.71', det.at_xpath('n:COFINS/n:COFINSAliq/n:vCOFINS', NS).text
  end

  test 'totals add up products, discount, freight and taxes' do
    total = doc(build).at_xpath('//n:ICMSTot', NS)
    assert_equal '250.00', total.at_xpath('n:vProd', NS).text
    assert_equal '20.00', total.at_xpath('n:vDesc', NS).text
    assert_equal '15.00', total.at_xpath('n:vFrete', NS).text
    assert_equal '245.00', total.at_xpath('n:vNF', NS).text
    assert_equal '245.00', total.at_xpath('n:vBC', NS).text
    assert_equal '29.40', total.at_xpath('n:vICMS', NS).text # 22.80 + 6.60
    assert_equal '24.38', total.at_xpath('n:vICMSUFDest', NS).text # base dupla: 18.91 + 5.47
  end

  test 'payment, notes and technical responsible are informed' do
    xml = doc(build)
    assert_equal '03', xml.at_xpath('//n:pag/n:detPag/n:tPag', NS).text
    assert_equal '1', xml.at_xpath('//n:pag/n:detPag/n:indPag', NS).text
    assert_equal 'Info fisco', xml.at_xpath('//n:infAdic/n:infAdFisco', NS).text
    assert_equal 'Pedido #1001 (loja virtual)', xml.at_xpath('//n:infAdic/n:infCpl', NS).text
    assert_equal '11222333000181', xml.at_xpath('//n:infRespTec/n:CNPJ', NS).text
  end

  test 'interstate sale without DIFAL configured is refused before reaching SEFAZ' do
    error = assert_raises(Nfe::XmlBuilder::Error) { build(nature: nature(difal: false)) }
    assert_match(/DIFAL/, error.message)
  end
end
