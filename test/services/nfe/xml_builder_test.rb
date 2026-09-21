require 'test_helper'

class Nfe::XmlBuilderTest < ActiveSupport::TestCase
  NS = { 'n' => 'http://www.portalfiscal.inf.br/nfe' }.freeze

  def company(overrides = {})
    Company.new({
      legal_name: 'Empresa Teste Ltda', trade_name: 'Teste', cnpj: '11222333000181', state_registration: '123456789',
      tax_regime: 1, street: 'Rua A', number: '10', neighbourhood: 'Centro', city: 'Belo Horizonte',
      city_ibge_code: '3106200', state: 'MG', zip: '30000-000', phone: '31 3333-4444',
      environment: :producao
    }.merge(overrides))
  end

  def recipient(overrides = {})
    { name: 'Cliente Destino SA', document: '25405327000174', ie_indicator: 1, state_registration: '987654321',
      street: 'Rua B', number: '20', complement: 'Sala 1', neighbourhood: 'Bairro', city: 'Belo Horizonte',
      city_ibge_code: '3106200', state: 'MG', zip: '31000-000', phone: '3199998888', email: 'c@example.com' }.merge(overrides)
  end

  def items
    [
      { code: 'SKU-1', description: 'Camiseta', ncm: '61091000', cest: nil, origin: 0, unit: 'UN', quantity: 2, unit_price: '10.00', cfop: '5102' },
      { code: 'SKU-2', description: 'Calça', ncm: '62034200', cest: '2806100', origin: 0, unit: 'PC', quantity: 1, unit_price: '5.50', cfop: '5102' }
    ]
  end

  def build(company: self.company, recipient: self.recipient, items: self.items, **opts)
    Nfe::XmlBuilder.new(
      company: company, recipient: recipient, items: items, number: 1, series: 1,
      operation_nature: 'Venda de mercadoria', issued_at: Time.utc(2026, 9, 20, 15, 0, 0), cnf: '12345678', **opts
    ).call
  end

  def doc(result)
    Nokogiri::XML(result.xml) { |config| config.strict }
  end

  test 'access key has 44 digits and the mod 11 check digit is correct' do
    known = '35080599999090910270550010000000015180051273'
    assert_equal 3, Nfe::XmlBuilder.access_key_check_digit(known[0, 43])

    key = build.access_key
    assert_equal 44, key.length
    assert_equal '31', key[0, 2]                # cUF
    assert_equal '2609', key[2, 4]              # AAMM
    assert_equal '11222333000181', key[6, 14]   # CNPJ
    assert_equal '55', key[20, 2]               # modelo
    assert_equal '001', key[22, 3]              # série
    assert_equal '000000001', key[25, 9]        # número
    assert_equal '1', key[34]                   # tpEmis
    assert_equal '12345678', key[35, 8]         # cNF
    assert_equal Nfe::XmlBuilder.access_key_check_digit(key[0, 43]).to_s, key[43]
  end

  test 'generates well formed NF-e 4.00 XML with the Id from the access key' do
    result = build
    inf = doc(result).at_xpath('//n:infNFe', NS)

    assert_equal "NFe#{result.access_key}", inf['Id']
    assert_equal '4.00', inf['versao']
    assert_equal 'Venda de mercadoria', inf.at_xpath('n:ide/n:natOp', NS).text
    assert_equal '55', inf.at_xpath('n:ide/n:mod', NS).text
    assert_equal '1', inf.at_xpath('n:ide/n:tpAmb', NS).text
    assert_equal '2026-09-20T12:00:00-03:00', inf.at_xpath('n:ide/n:dhEmi', NS).text
    assert_equal '3106200', inf.at_xpath('n:ide/n:cMunFG', NS).text
  end

  test 'is serialized without indentation so the signature canonicalization stays stable' do
    refute_match(/>\s+</, build.xml)
  end

  test 'emitter and recipient blocks' do
    inf = doc(build).at_xpath('//n:infNFe', NS)

    assert_equal '11222333000181', inf.at_xpath('n:emit/n:CNPJ', NS).text
    assert_equal '1', inf.at_xpath('n:emit/n:CRT', NS).text
    assert_equal '30000000', inf.at_xpath('n:emit/n:enderEmit/n:CEP', NS).text
    assert_equal '25405327000174', inf.at_xpath('n:dest/n:CNPJ', NS).text
    assert_equal 'Cliente Destino SA', inf.at_xpath('n:dest/n:xNome', NS).text
    assert_equal '1', inf.at_xpath('n:dest/n:indIEDest', NS).text
    assert_equal '987654321', inf.at_xpath('n:dest/n:IE', NS).text
  end

  test 'a CPF recipient uses the CPF tag and no IE' do
    inf = doc(build(recipient: recipient(document: '12345678909', ie_indicator: 9, state_registration: nil))).at_xpath('//n:infNFe', NS)

    assert_equal '12345678909', inf.at_xpath('n:dest/n:CPF', NS).text
    assert_nil inf.at_xpath('n:dest/n:CNPJ', NS)
    assert_nil inf.at_xpath('n:dest/n:IE', NS)
  end

  test 'item lines and totals' do
    result = build
    inf = doc(result).at_xpath('//n:infNFe', NS)
    dets = inf.xpath('n:det', NS)

    assert_equal 2, dets.size
    assert_equal '1', dets[0]['nItem']
    assert_equal '61091000', dets[0].at_xpath('n:prod/n:NCM', NS).text
    assert_equal '5102', dets[0].at_xpath('n:prod/n:CFOP', NS).text
    assert_equal '2.0000', dets[0].at_xpath('n:prod/n:qCom', NS).text
    assert_equal '10.0000', dets[0].at_xpath('n:prod/n:vUnCom', NS).text
    assert_equal '20.00', dets[0].at_xpath('n:prod/n:vProd', NS).text
    assert_nil dets[0].at_xpath('n:prod/n:CEST', NS)
    assert_equal '2806100', dets[1].at_xpath('n:prod/n:CEST', NS).text
    assert_equal 'PC', dets[1].at_xpath('n:prod/n:uCom', NS).text

    assert_equal '25.50', inf.at_xpath('n:total/n:ICMSTot/n:vProd', NS).text
    assert_equal '25.50', inf.at_xpath('n:total/n:ICMSTot/n:vNF', NS).text
    assert_equal BigDecimal('25.50'), result.total
  end

  test 'idDest is 1 for the same state and 2 for another state' do
    same = doc(build).at_xpath('//n:ide/n:idDest', NS).text
    other = doc(build(recipient: recipient(state: 'SP', city_ibge_code: '3550308'))).at_xpath('//n:ide/n:idDest', NS).text

    assert_equal '1', same
    assert_equal '2', other
  end

  test 'homologation masks the recipient name and the first item description' do
    inf = doc(build(company: company(environment: :homologacao))).at_xpath('//n:infNFe', NS)

    assert_equal '2', inf.at_xpath('n:ide/n:tpAmb', NS).text
    assert_equal 'NF-E EMITIDA EM AMBIENTE DE HOMOLOGACAO - SEM VALOR FISCAL', inf.at_xpath('n:dest/n:xNome', NS).text
    assert_equal 'NF-E EMITIDA EM AMBIENTE DE HOMOLOGACAO - SEM VALOR FISCAL', inf.xpath('n:det', NS)[0].at_xpath('n:prod/n:xProd', NS).text
    assert_equal 'Calça', inf.xpath('n:det', NS)[1].at_xpath('n:prod/n:xProd', NS).text
  end

  test 'Simples Nacional uses ICMSSN102 and PISOutr/COFINSOutr' do
    det = doc(build).at_xpath('//n:det', NS)

    assert_equal '102', det.at_xpath('n:imposto/n:ICMS/n:ICMSSN102/n:CSOSN', NS).text
    assert_equal '0', det.at_xpath('n:imposto/n:ICMS/n:ICMSSN102/n:orig', NS).text
    assert_equal '49', det.at_xpath('n:imposto/n:PIS/n:PISOutr/n:CST', NS).text
    assert_equal '0.00', det.at_xpath('n:imposto/n:PIS/n:PISOutr/n:vPIS', NS).text
    assert_equal '49', det.at_xpath('n:imposto/n:COFINS/n:COFINSOutr/n:CST', NS).text
  end

  test 'Normal regime with an exempt CST uses ICMS40 and PIS/COFINS not taxed uses the NT tags' do
    normal = company(tax_regime: 3, icms_situation: '40', pis_cst: '07', cofins_cst: '07')
    det = doc(build(company: normal)).at_xpath('//n:det', NS)

    assert_equal '40', det.at_xpath('n:imposto/n:ICMS/n:ICMS40/n:CST', NS).text
    assert_equal '07', det.at_xpath('n:imposto/n:PIS/n:PISNT/n:CST', NS).text
    assert_equal '07', det.at_xpath('n:imposto/n:COFINS/n:COFINSNT/n:CST', NS).text
  end

  test 'unsupported tax situations are rejected with a clear message' do
    assert_raises(Nfe::XmlBuilder::Error) { build(company: company(icms_situation: '500')) }
    assert_raises(Nfe::XmlBuilder::Error) { build(company: company(tax_regime: 3, icms_situation: '102')) }
    assert_raises(Nfe::XmlBuilder::Error) { build(company: company(pis_cst: '01')) }
  end

  test 'missing fiscal data raises readable errors' do
    error = assert_raises(Nfe::XmlBuilder::Error) { build(items: [items[0].merge(ncm: nil)]) }
    assert_match(/NCM ausente para o item SKU-1/, error.message)

    error = assert_raises(Nfe::XmlBuilder::Error) { build(recipient: recipient(city_ibge_code: nil)) }
    assert_match(/IBGE do destinatário/, error.message)

    error = assert_raises(Nfe::XmlBuilder::Error) { build(company: company(state_registration: nil)) }
    assert_match(/Inscrição Estadual da empresa/, error.message)

    assert_raises(Nfe::XmlBuilder::Error) { build(items: []) }
  end

  test 'a random cNF is generated and differs from the number when not injected' do
    result = Nfe::XmlBuilder.new(company: company, recipient: recipient, items: items, number: 1, series: 1,
                                 operation_nature: 'Venda', issued_at: Time.utc(2026, 9, 20)).call
    cnf = result.access_key[35, 8]

    assert_match(/\A\d{8}\z/, cnf)
    assert_not_equal '00000001', cnf
  end
end
