require 'test_helper'
require_relative '../support/finance_factory'

# Notas Fiscais de Entrada (XML de compra) e Colocação de estoque (CSV do Log02 e do Log03, conferência e remessa).
class StockPlacementsTest < ActionDispatch::IntegrationTest
  include FinanceFactory

  KEY = '42261108980135000172550010000021911001430801'.freeze

  def setup
    @admin = finance_user('Admin Entrada')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @common = finance_user('Comum Entrada')
    @company = Company.new(legal_name: 'CHASE 02', trade_name: 'Chase 02 - Contagem', cnpj: '25.405.327/0002-55', street: 'R', number: '1',
                           neighbourhood: 'B', city: 'Contagem', city_ibge_code: '3118601', state: 'MG', zip: '32000000')
    @company.save!(validate: false)
  end

  def nfe_xml(key: KEY, dest: '25405327000255', items: [['TAI-1824-P', 141, '51.10'], ['TAI-1824-M', 141, '51.10'], ['TAI-1825-G', 110, '53.30']])
    dets = items.each_with_index.map do |(sku, qty, price), i|
      <<~DET
        <det nItem="#{i + 1}"><prod><cProd>#{sku}</cProd><cEAN>SEM GTIN</cEAN><xProd>PRODUTO #{sku}</xProd><NCM>61062000</NCM><CFOP>6101</CFOP>
        <uCom>PC</uCom><qCom>#{qty}.0000</qCom><vUnCom>#{price}</vUnCom><vProd>#{format('%.2f', qty * price.to_f)}</vProd></prod>
        <imposto><ICMS><ICMS00><orig>0</orig></ICMS00></ICMS></imposto></det>
      DET
    end.join
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <nfeProc xmlns="http://www.portalfiscal.inf.br/nfe" versao="4.00"><NFe><infNFe Id="NFe#{key}" versao="4.00">
      <ide><natOp>VENDA FORA DO ESTADO</natOp><serie>1</serie><nNF>2191</nNF><dhEmi>2026-11-16T00:00:00-03:00</dhEmi></ide>
      <emit><CNPJ>08980135000172</CNPJ><xNome>FORNECEDOR TESTE LTDA</xNome><enderEmit><UF>SC</UF></enderEmit></emit>
      <dest><CNPJ>#{dest}</CNPJ><xNome>CHASE</xNome></dest>
      #{dets}
      <total><ICMSTot><vProd>20000.00</vProd><vNF>19000.00</vNF></ICMSTot></total>
      </infNFe></NFe><protNFe><infProt><cStat>100</cStat></infProt></protNFe></nfeProc>
    XML
  end

  def upload_xml(xml = nfe_xml)
    post stock_entries_path, params: { xml: Rack::Test::UploadedFile.new(StringIO.new(xml), 'application/xml', original_filename: 'nota.xml') }
  end

  def upload_csv(entry, side, text)
    post upload_stock_placement_path(entry, side: side), params: { csv: Rack::Test::UploadedFile.new(StringIO.new(text), 'text/csv', original_filename: "#{side}.csv") }
  end

  test 'importa o xml da nota de entrada com os itens e recusa repetida e de outro cnpj' do
    sign_in @admin
    upload_xml
    entry = StockEntry.last
    assert_redirected_to stock_entry_path(entry)
    assert_equal 2191, entry.number
    assert_equal 'FORNECEDOR TESTE LTDA', entry.supplier_name
    assert_equal @company, entry.company
    assert entry.authorized
    assert_equal 392, entry.pieces
    assert_equal({ 'TAI-1824-P' => 141, 'TAI-1824-M' => 141, 'TAI-1825-G' => 110 }, entry.quantities)
    assert entry.xml.attached?
    assert_equal 'aguardando', entry.status

    get stock_entry_path(entry)
    assert_response :success
    assert_match 'TAI-1824-P', response.body

    upload_xml
    assert_match 'já foi importada', flash[:alert]
    upload_xml(nfe_xml(key: '4' * 44, dest: '11222333000181'))
    assert_match 'não é uma empresa da Chase', flash[:alert]
    assert_equal 1, StockEntry.count
  end

  test 'csv de cada lado e a conferencia com a nota' do
    sign_in @admin
    upload_xml
    entry = StockEntry.last

    upload_csv(entry, 'log02', "sku;estoque\nTAI-1824-P;100\nTAI-1824-M;141\n")
    assert_redirected_to stock_placement_path(entry)
    upload_csv(entry, 'log03', "SKU,Estoque\ntai-1824-p,41\nTAI-1825-G,100\nXXX-1,5\n")
    entry.reload
    assert_equal({ 'TAI-1824-P' => 41, 'TAI-1825-G' => 100, 'XXX-1' => 5 }, entry.placement('log03').quantities)
    assert_not entry.balanced?
    rec = entry.reconciliation.index_by { |r| r[:sku] }
    assert_equal(-10, rec['TAI-1825-G'][:diff])
    assert rec['XXX-1'][:outside]
    assert_equal 'em_colocacao', entry.status

    get stock_placement_path(entry), headers: { 'Turbo-Frame' => 'placement_panel' }
    assert_response :success
    assert_select 'turbo-frame#placement_panel'
    assert_select 'tr.is-bad', 2
    assert_select 'form[action$=?] button[disabled]', '/nota/log02'

    upload_csv(entry, 'log03', "sku;estoque\nTAI-1824-P;41\nTAI-1825-G;110\n")
    assert entry.reload.balanced?

    upload_csv(entry, 'log02', "sku;qtd\nTAI-1824-P;abc\n")
    assert_match 'não é um número inteiro', flash[:alert]
    assert_equal 241, entry.reload.placement('log02').pieces
  end

  test 'sem conferencia batendo ou sem configuracao nao gera a remessa' do
    sign_in @admin
    upload_xml
    entry = StockEntry.last
    upload_csv(entry, 'log02', "sku;estoque\nTAI-1824-P;141\n")
    post generate_stock_placement_path(entry, side: 'log02')
    assert_match 'Configurações', flash[:alert]

    nature = OperationNature.new(company: @company, description: '5905 - Remessa para depósito', cfop: '5905', kind: :other, purpose: 1)
    nature.save!(validate: false)
    StockPlacementConfig.for('log02').update!(company: @company, operation_nature: nature)
    StockPlacementConfig.for('log03').update!(company: @company, operation_nature: nature)
    post generate_stock_placement_path(entry, side: 'log02')
    assert_match 'ciente', flash[:alert] # só o Log02 subiu
    post generate_stock_placement_path(entry, side: 'log02'), params: { ciente: '1' }
    assert_match 'certificado', flash[:alert] # passou da trava; a empresa de teste não tem certificado
    get stock_placement_path(entry)
    assert_select 'input[type=checkbox][name=ciente]', 1 # só o lado com CSV

    upload_csv(entry, 'log02', "sku;estoque\nTAI-1824-P;141\nTAI-1824-M;141\n")
    upload_csv(entry, 'log03', "sku;estoque\nTAI-1825-G;110\n")
    assert entry.reload.balanced?
    post generate_stock_placement_path(entry, side: 'log02')
    assert_match 'certificado', flash[:alert] # empresa de teste sem certificado digital
    assert_equal 0, FiscalNote.where.not(stock_placement_id: nil).count
  end

  test 'configuracoes salvam empresa, natureza e destinatario de cada lado' do
    sign_in @admin
    get edit_stock_placement_config_path
    assert_response :success
    assert_select 'input[name=?][value=?]', 'configs[log02][recipient][name]', 'CLI CONTAGEM'
    patch stock_placement_config_path, params: { configs: { log02: { company_id: @company.id, recipient: { name: 'CORREIOS LOG', document: '34.028.316/9005-20' } },
                                                            log03: { company_id: '' } } }
    assert_redirected_to edit_stock_placement_config_path
    assert_equal @company, StockPlacementConfig.for('log02').company
    assert_equal 'CORREIOS LOG', StockPlacementConfig.for('log02').recipient_data['name']
    assert_equal 'CLI CONTAGEM', StockPlacementConfig.for('log03').recipient_data['name']
  end

  test 'sem permissao nao entra nem pelo link' do
    sign_in @common
    [stock_entries_path, stock_placements_path, edit_stock_placement_config_path].each do |path|
      get path
      assert_redirected_to root_path, path
    end
    upload_xml
    assert_equal 0, StockEntry.count
  end

  test 'parse do csv aceita separadores, cabecalhos e soma repetidos' do
    assert_equal [['A-1', 3], ['B-2', 2]], StockPlacement.parse_csv("﻿Sku;Quantidade\na-1;1\nA-1;2\nB-2;2,0\n")
    assert_equal [['A-1', 5]], StockPlacement.parse_csv("codigo,estoque\nA-1,5\n")
    assert_raises(ArgumentError) { StockPlacement.parse_csv("produto;qtd\nA;1") }
    assert_raises(ArgumentError) { StockPlacement.parse_csv('') }
  end
end
