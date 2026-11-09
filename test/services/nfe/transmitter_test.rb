require 'test_helper'
require 'webmock/minitest'
require_relative '../../support/shopify_order_factory'
require_relative '../../support/nfe_company_factory'

class Nfe::TransmitterTest < ActiveSupport::TestCase
  include NfeCompanyFactory
  NFE_NS = 'http://www.portalfiscal.inf.br/nfe'.freeze
  NS = { 'n' => NFE_NS }.freeze

  # Cliente falso: devolve as respostas na ordem e registra as chamadas.
  class FakeClient
    attr_reader :calls

    def initialize(*responses)
      @responses = responses
      @calls = []
    end

    %i[authorize receipt consult].each do |name|
      define_method(name) do |*args, **kwargs|
        @calls << [name, args, kwargs]
        response = @responses.shift
        raise response if response.is_a?(Exception)

        Nokogiri::XML(response)
      end
    end
  end

  def setup
    @company = create_nfe_company
    nature = create_sale_nature(@company)
    Product.create!(sku: 'SKU-1', ncm: '61091000')
    Product.create!(sku: 'SKU-2', ncm: '62034200')
    @note = Nfe::ShopifyGenerator.call(
      company: @company, nature: nature, shopify_order: Nfe::ShopifyOrder.new(ShopifyOrderFactory.node),
      recipient: { name: 'Maria', document: '52998224725', street: 'Rua A', number: '1', neighbourhood: 'Centro',
                   city: 'Belo Horizonte', city_ibge_code: '3106200', state: 'MG', zip: '30140071' },
      payment: { method: '17' }
    )
  end

  def prot(code, message, protocol: '131260000000001')
    "<protNFe versao=\"4.00\"><infProt><tpAmb>2</tpAmb><verAplic>MG4</verAplic><chNFe>#{@note.access_key}</chNFe>" \
      "<dhRecbto>2026-10-28T10:00:00-03:00</dhRecbto><nProt>#{protocol}</nProt><digVal>abc=</digVal>" \
      "<cStat>#{code}</cStat><xMotivo>#{message}</xMotivo></infProt></protNFe>"
  end

  def ret_envi(code, message, inner = '')
    "<retEnviNFe xmlns=\"#{NFE_NS}\" versao=\"4.00\"><tpAmb>2</tpAmb><cStat>#{code}</cStat><xMotivo>#{message}</xMotivo>#{inner}</retEnviNFe>"
  end

  def transmit(client, **opts)
    Nfe::Transmitter.call(@note, client: client, wait: 0, **opts)
  end

  test 'authorized: stores the protocol and replaces the XML with the nfeProc' do
    client = FakeClient.new(ret_envi('104', 'Lote processado', prot('100', 'Autorizado o uso da NF-e')))
    transmit(client)

    assert @note.reload.autorizada?
    assert_equal '131260000000001', @note.protocol
    assert_equal '100', @note.sefaz_status_code
    assert @note.authorized_at
    proc_xml = Nokogiri::XML(@note.xml.download)
    assert proc_xml.at_xpath('/n:nfeProc/n:NFe/n:infNFe', NS)
    assert proc_xml.at_xpath('/n:nfeProc/n:protNFe/n:infProt/n:nProt', NS)
    assert_equal :authorize, client.calls.first.first
    assert_match(/\A\d{15}\z/, client.calls.first.last[:batch_id])
  end

  test 'rejected: keeps the code and message so the order can be fixed and issued again' do
    transmit(FakeClient.new(ret_envi('104', 'Lote processado', prot('225', 'Falha no Schema XML'))))

    assert @note.reload.rejeitada?
    assert_equal '225', @note.sefaz_status_code
    assert_equal 'Rejeição 225: Falha no Schema XML', @note.error_message
  end

  test 'batch-level rejection is a rejection too' do
    transmit(FakeClient.new(ret_envi('215', 'Falha no schema XML')))
    assert @note.reload.rejeitada?
    assert_equal '215', @note.sefaz_status_code
  end

  test 'asynchronous answer: polls the receipt until processed' do
    received = ret_envi('103', 'Lote recebido', '<infRec><nRec>310000000000001</nRec><tMed>1</tMed></infRec>')
    processing = "<retConsReciNFe xmlns=\"#{NFE_NS}\" versao=\"4.00\"><cStat>105</cStat><xMotivo>Em processamento</xMotivo></retConsReciNFe>"
    done = "<retConsReciNFe xmlns=\"#{NFE_NS}\" versao=\"4.00\"><cStat>104</cStat><xMotivo>Lote processado</xMotivo>" \
           "#{prot('100', 'Autorizado')}</retConsReciNFe>"
    client = FakeClient.new(received, processing, done)
    transmit(client)

    assert @note.reload.autorizada?
    assert_equal '310000000000001', @note.sefaz_receipt
    assert_equal [:authorize, :receipt, :receipt], client.calls.map(&:first)
  end

  test 'duplicate: recovers the protocol of the note already authorized' do
    consult = "<retConsSitNFe xmlns=\"#{NFE_NS}\" versao=\"4.00\"><cStat>100</cStat><xMotivo>Autorizado</xMotivo>" \
              "#{prot('100', 'Autorizado', protocol: '131260000000099')}</retConsSitNFe>"
    client = FakeClient.new(ret_envi('104', 'Lote processado', prot('204', 'Duplicidade de NF-e')), consult)
    transmit(client)

    assert @note.reload.autorizada?
    assert_equal '131260000000099', @note.protocol
    assert_equal [:authorize, :consult], client.calls.map(&:first)
  end

  test 'communication failure leaves the note in error, and a consult that SEFAZ does not know frees it' do
    transmit(FakeClient.new(Nfe::Sefaz::Client::Error.new('Falha de comunicação com a SEFAZ: timeout')))
    assert @note.reload.erro?
    assert_match(/timeout/, @note.error_message)

    unknown = "<retConsSitNFe xmlns=\"#{NFE_NS}\" versao=\"4.00\"><cStat>217</cStat><xMotivo>NF-e não consta</xMotivo></retConsSitNFe>"
    transmit(FakeClient.new(unknown), consult: true)
    assert @note.reload.assinada?
  end

  test 'talks to the environment of the note even after the company switched environment' do
    @company.update_column(:environment, Company.environments[:producao])
    stub_request(:post, 'https://hnfe.fazenda.mg.gov.br/nfe2/services/NFeAutorizacao4').to_return(
      status: 200,
      body: '<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body>' \
            '<nfeResultMsg xmlns="http://www.portalfiscal.inf.br/nfe/wsdl/NFeAutorizacao4">' \
            "#{ret_envi('104', 'Lote processado', prot('100', 'Autorizado'))}</nfeResultMsg></soap:Body></soap:Envelope>"
    )

    Nfe::Transmitter.call(@note.reload, wait: 0)

    assert @note.reload.autorizada?
  end

  test 'client posts the SOAP envelope to the authorizer of the company state with mutual TLS' do
    request = nil
    stub_request(:post, 'https://hnfe.fazenda.mg.gov.br/nfe2/services/NFeAutorizacao4').to_return do |req|
      request = req
      body = '<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body>' \
             '<nfeResultMsg xmlns="http://www.portalfiscal.inf.br/nfe/wsdl/NFeAutorizacao4">' \
             "#{ret_envi('104', 'Lote processado', prot('100', 'Autorizado'))}</nfeResultMsg></soap:Body></soap:Envelope>"
      { status: 200, body: body }
    end

    Nfe::Transmitter.call(@note, wait: 0)

    assert @note.reload.autorizada?
    assert_match(%r{action="http://www.portalfiscal.inf.br/nfe/wsdl/NFeAutorizacao4/nfeAutorizacaoLote"}, request.headers['Content-Type'])
    body = Nokogiri::XML(request.body)
    assert body.at_xpath('//n:enviNFe/n:NFe/n:infNFe', NS)
    assert_equal '1', body.at_xpath('//n:enviNFe/n:indSinc', NS).text
  end

  test 'client turns HTTP errors into a readable communication error' do
    stub_request(:post, 'https://hnfe.fazenda.mg.gov.br/nfe2/services/NFeAutorizacao4').to_return(status: 500, body: 'erro')
    Nfe::Transmitter.call(@note, wait: 0)
    assert @note.reload.erro?
    assert_match(/HTTP 500/, @note.error_message)
  end
end
