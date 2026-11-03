require 'test_helper'

class Nfe::DanfeTest < ActiveSupport::TestCase
  NS = { 'n' => 'http://www.portalfiscal.inf.br/nfe' }.freeze
  KEY = '31261025405327000336550010000000011566588680'.freeze

  def company
    Company.new(legal_name: 'Chase Brasil Comercio Ltda', cnpj: '25405327000336', state_registration: '0029090240268',
                tax_regime: 3, street: 'Av. Raja Gabaglia', number: '4343', neighbourhood: 'Santa Lucia', city: 'Belo Horizonte',
                city_ibge_code: '3106200', state: 'MG', zip: '30350577', phone: '3187216250', email: 'fiscal@example.com',
                environment: :producao)
  end

  def nature
    OperationNature.new(company: company, description: 'Venda Online', cfop: '?102', icms_situation: '00', icms_rate: 18,
                        difal: true, pis_cst: '01', pis_rate: 0.65, cofins_cst: '01', cofins_rate: 3).tap(&:valid?)
  end

  # nfeProc com a nota montada pelo XmlBuilder e um protocolo de autorização.
  def proc_xml(item_count: 1, state: 'SP', authorized: true)
    items = Array.new(item_count) do |i|
      { code: "SKU-#{i}", description: "Camiseta Ação #{i}", ncm: '61091000', origin: 0, quantity: 1, unit_price: '100.00',
        freight: '0', cfop: state == 'MG' ? '5102' : '6102' }
    end
    recipient = { name: 'Maria José', document: '52998224725', ie_indicator: 9, street: 'Rua A', number: '1',
                  neighbourhood: 'Centro', city: 'Cidade', city_ibge_code: state == 'MG' ? '3106200' : '3550308', state: state, zip: '01001000' }
    nfe = Nfe::XmlBuilder.new(company: company, recipient: recipient, items: items, number: 1234, series: 1,
                              operation_nature: 'Venda Online', issued_at: Time.utc(2026, 10, 28, 15), cnf: '12345678',
                              final_consumer: true, presence: '2', freight_mode: '0', tax: nature.tax_rules,
                              payments: [{ method: '17', amount: (100 * item_count).to_s }]).call
    prot = authorized ? '<protNFe versao="4.00"><infProt><tpAmb>1</tpAmb><nProt>131260000000001</nProt>' \
                        '<dhRecbto>2026-10-28T12:00:05-03:00</dhRecbto><cStat>100</cStat><xMotivo>Autorizado</xMotivo></infProt></protNFe>' : ''
    @key = nfe.access_key
    %(<nfeProc xmlns="http://www.portalfiscal.inf.br/nfe" versao="4.00">#{nfe.xml}#{prot}</nfeProc>)
  end

  def pages(pdf)
    pdf.scan(%r{/Type /Page\b}).size
  end

  # Texto do PDF: o Prawn grava cada linha como um array TJ de trechos em hexadecimal (Windows-1252).
  def text(pdf)
    pdf.scan(/\[([^\]]*)\] TJ/).map do |(array)|
      array.scan(/<([0-9a-f]*)>/).map { |(hex)| [hex].pack('H*') }.join.force_encoding('Windows-1252').encode('UTF-8')
    end.join("\n")
  end

  test 'Code 128C check digit and widths' do
    symbols = Nfe::Code128.symbols('102030')
    # start C (105) + 10*1 + 20*2 + 30*3 = 245 % 103 = 39
    assert_equal [105, 10, 20, 30, 39, 106], symbols
    assert(Nfe::Code128::PATTERNS.first(106).all? { |p| p.chars.sum(&:to_i) == 11 })
    assert_equal 11 * 24 + 13, Nfe::Code128.widths(KEY).sum
    assert_raises(ArgumentError) { Nfe::Code128.symbols('123') }
  end

  test 'renders an A4 DANFE with the access key, number and totals' do
    danfe = Nfe::Danfe.new(proc_xml)
    pdf = danfe.render

    assert pdf.start_with?('%PDF')
    assert_equal 1, pages(pdf)
    assert_equal "DANFE-#{@key}.pdf", danfe.filename
    assert_includes text(pdf), @key.scan(/\d{4}/).join(' ')
    assert_includes text(pdf), 'Nº 000.001.234'
    assert_includes text(pdf), '131260000000001 - 28/10/2026 12:00:05'
    assert_includes text(pdf), 'Camiseta Ação 0'
  end

  test 'many items continue on the next sheets' do
    pdf = Nfe::Danfe.new(proc_xml(item_count: 90)).render
    assert_operator pages(pdf), :>=, 3
    assert_includes text(pdf), "FOLHA 3/#{pages(pdf)}"
  end

  test 'a note without protocol is marked as having no fiscal value' do
    pdf = Nfe::Danfe.new(proc_xml(authorized: false)).render
    assert_includes text(pdf), 'NOTA NÃO AUTORIZADA - SEM VALOR FISCAL'
  end
end
