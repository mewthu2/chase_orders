require 'test_helper'
require_relative '../../support/nfe_test_certificate'
require_relative '../../support/nfe_schema'

# NF-e de remessa de um lado da Colocação de estoque: itens do CSV, valor da nota de entrada, destinatário do
# depósito do Correios, rascunho para conferir antes de emitir.
class Nfe::PlacementGeneratorTest < ActiveSupport::TestCase
  NS = { 'n' => 'http://www.portalfiscal.inf.br/nfe' }.freeze

  def setup
    file = Tempfile.new(['cert', '.pfx'], binmode: true)
    file.write(NfeTestCertificate.pfx)
    file.rewind
    @company = Company.create!(legal_name: 'Empresa Emissora Ltda', cnpj: '11.222.333/0001-81', state_registration: '123456789', tax_regime: 1,
                               street: 'Rua A', number: '10', neighbourhood: 'Centro', city: 'Contagem', city_ibge_code: '3118601', state: 'MG',
                               zip: '32000-000', certificate_file: Rack::Test::UploadedFile.new(file.path, 'application/x-pkcs12'), certificate_password: 'senha123')
    @nature = @company.operation_natures.create!(description: 'Remessa para depósito fechado', kind: :other, cfop: '5905', final_consumer: false,
                                                 icms_situation: '400', pis_cst: '08', cofins_cst: '08', notes: 'Remessa para armazenagem.')
    %w[log02 log03].each { |s| StockPlacementConfig.for(s).update!(company: @company, operation_nature: @nature) }
    @entry = StockEntry.create!(company: @company, access_key: '4' * 44, number: 2191, series: 1, supplier_name: 'Fornecedor', supplier_cnpj: '08980135000172', total_value: 1000)
    @entry.items.create!(position: 1, sku: 'TAI-1', description: 'TAILOR V - P', ncm: '61062000', cfop: '6101', unit: 'PC', quantity: 10, unit_price: 50, total: 500, origin: 0)
    @entry.items.create!(position: 2, sku: 'TAI-2', description: 'TAILOR V - M', ncm: '61062000', cfop: '6101', unit: 'PC', quantity: 5, unit_price: 40, total: 200, origin: 0)
    @log02 = @entry.placements.create!(side: 'log02', items: [['TAI-1', 7], ['TAI-2', 5]])
    @entry.placements.create!(side: 'log03', items: [['TAI-1', 3]])
  end

  test 'gera a remessa do lado como rascunho, com os itens do csv pelo valor da nota de entrada' do
    note = Nfe::PlacementGenerator.call(placement: @log02.reload, environment: 'homologacao')

    assert note.rascunho?
    assert_equal 'remessa', note.role
    assert_equal @log02, note.stock_placement
    assert_equal '5905', note.cfop_summary
    assert_equal BigDecimal('550'), note.total_value # 7 × 50 + 5 × 40
    xml = note.xml.download
    assert_equal [], NfeSchema.errors(xml)
    doc = Nokogiri::XML(xml)
    assert_equal %w[TAI-1 TAI-2], doc.xpath('//n:det/n:prod/n:cProd', NS).map(&:text)
    assert_equal '34028316900520', doc.at_xpath('//n:dest/n:CNPJ', NS).text # CLI CONTAGEM (em homologação o nome vira o aviso da SEFAZ)
    assert_match 'NF-e de entrada nº 2191', doc.at_xpath('//n:infCpl', NS).text

    error = assert_raises(Nfe::PlacementGenerator::Error) { Nfe::PlacementGenerator.call(placement: @log02.reload, environment: 'homologacao') }
    assert_match 'ativa', error.message
  end

  test 'com divergencia so gera se a pessoa estiver ciente, e guarda quem foi' do
    @entry.placement('log03').update!(items: [['TAI-1', 2]])
    error = assert_raises(Nfe::PlacementGenerator::Error) { Nfe::PlacementGenerator.call(placement: @log02.reload, environment: 'homologacao') }
    assert_match 'ciente', error.message

    user = User.create!(name: 'Ciente', email: 'ciente@example.com', password: 'password123')
    note = Nfe::PlacementGenerator.call(placement: @log02.reload, environment: 'homologacao', acknowledged_by: user)
    assert note.rascunho?
    assert_equal user, @log02.reload.divergence_acknowledged_by
    assert @log02.divergence_acknowledged_at
  end

  test 'sem divergencia nao grava ciente' do
    Nfe::PlacementGenerator.call(placement: @log02.reload, environment: 'homologacao', acknowledged_by: User.create!(name: 'X', email: 'x@example.com', password: 'password123'))
    assert_nil @log02.reload.divergence_acknowledged_at
  end
end
