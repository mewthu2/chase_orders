require 'test_helper'
require_relative '../../support/shopify_order_factory'
require_relative '../../support/nfe_company_factory'

# Cancelamento da NF-e na SEFAZ (evento 110111).
class Nfe::CancellerTest < ActiveSupport::TestCase
  include NfeCompanyFactory
  NFE_NS = 'http://www.portalfiscal.inf.br/nfe'.freeze
  NS = { 'n' => NFE_NS, 'ds' => 'http://www.w3.org/2000/09/xmldsig#' }.freeze
  REASON = 'Nota emitida com a natureza errada, sera emitida outra'.freeze

  class FakeClient
    attr_reader :calls

    def initialize(response)
      @response = response
      @calls = []
    end

    def event(signed, batch_id:)
      @calls << [signed, batch_id]
      raise @response if @response.is_a?(Exception)

      Nokogiri::XML(@response)
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
    @note.update!(status: :autorizada, protocol: '131260000000001', authorized_at: 1.hour.ago)
    @user = User.create!(name: 'Fiscal', email: 'fiscal_cancel@example.com', password: 'password123')
  end

  def ret_env_evento(code, message, batch: '128')
    "<retEnvEvento xmlns=\"#{NFE_NS}\" versao=\"1.00\"><idLote>1</idLote><tpAmb>2</tpAmb><verAplic>MG</verAplic><cOrgao>31</cOrgao>" \
      "<cStat>#{batch}</cStat><xMotivo>Lote de evento processado</xMotivo>" \
      "<retEvento versao=\"1.00\"><infEvento><tpAmb>2</tpAmb><verAplic>MG</verAplic><cOrgao>31</cOrgao><cStat>#{code}</cStat>" \
      "<xMotivo>#{message}</xMotivo><chNFe>#{@note.access_key}</chNFe><tpEvento>110111</tpEvento><nSeqEvento>1</nSeqEvento>" \
      "<dhRegEvento>2026-11-16T17:00:00-03:00</dhRegEvento><nProt>131260000000999</nProt></infEvento></retEvento></retEnvEvento>"
  end

  def cancel(client, reason: REASON)
    Nfe::Canceller.call(@note, reason: reason, user: @user, client: client)
  end

  test 'sends the signed 110111 event with the protocol and the reason, and the note becomes canceled' do
    client = FakeClient.new(ret_env_evento('135', 'Evento registrado e vinculado a NF-e'))

    cancel(client, reason: "  #{REASON}\n ")

    event = Nokogiri::XML(client.calls.first[0])
    info = event.at_xpath('//n:infEvento', NS)
    assert_equal "ID110111#{@note.access_key}01", info['Id']
    assert_equal '31', info.at_xpath('n:cOrgao', NS).text
    assert_equal '2', info.at_xpath('n:tpAmb', NS).text, 'nota de homologação cancela em homologação'
    assert_equal @note.access_key, info.at_xpath('n:chNFe', NS).text
    assert_equal '110111', info.at_xpath('n:tpEvento', NS).text
    assert_equal '131260000000001', info.at_xpath('n:detEvento/n:nProt', NS).text
    assert_equal REASON, info.at_xpath('n:detEvento/n:xJust', NS).text
    assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d-03:00\z/, info.at_xpath('n:dhEvento', NS).text)
    assert_equal "#ID110111#{@note.access_key}01", event.at_xpath('//ds:Reference', NS)['URI']

    @note.reload
    assert @note.cancelada?
    assert_equal [REASON, '131260000000999', 'Fiscal'], [@note.cancel_reason, @note.cancel_protocol, @note.canceled_by]
    assert @note.canceled_at.present?
    proc_event = Nokogiri::XML(@note.cancel_xml.download)
    assert proc_event.at_xpath('/n:procEventoNFe/n:evento/ds:Signature', NS)
    assert_equal '135', proc_event.at_xpath('/n:procEventoNFe/n:retEvento/n:infEvento/n:cStat', NS).text
    assert_not FiscalNote.active_for?(@note.order) if @note.order
  end

  test 'cancellation out of the deadline accepted by SEFAZ (155) also cancels' do
    cancel(FakeClient.new(ret_env_evento('155', 'Cancelamento homologado fora de prazo')))

    assert @note.reload.cancelada?
  end

  test 'a refused event keeps the note authorized and shows the SEFAZ reason' do
    error = assert_raises(Nfe::Canceller::Error) { cancel(FakeClient.new(ret_env_evento('501', 'Rejeicao: Prazo de cancelamento superior ao previsto na Legislacao'))) }

    assert_match(/501 Rejeicao: Prazo de cancelamento/, error.message)
    assert @note.reload.autorizada?
    assert_not @note.cancel_xml.attached?
  end

  test 'the reason needs 15 to 255 characters and only authorized notes can be canceled' do
    client = FakeClient.new(ret_env_evento('135', 'ok'))

    assert_raises(Nfe::Canceller::Error) { cancel(client, reason: 'curto demais') }
    assert_raises(Nfe::Canceller::Error) { cancel(client, reason: 'x' * 256) }
    @note.update!(status: :rejeitada)
    error = assert_raises(Nfe::Canceller::Error) { cancel(client) }
    assert_match(/Só nota autorizada/, error.message)
    assert_empty client.calls
  end

  test 'a communication failure is reported and nothing changes' do
    error = assert_raises(Nfe::Canceller::Error) { cancel(FakeClient.new(Nfe::Sefaz::Client::Error.new('timeout'))) }

    assert_match(/timeout/, error.message)
    assert @note.reload.autorizada?
  end

  test 'the event web service exists for the authorizers' do
    assert_equal 'https://nfe.fazenda.mg.gov.br/nfe2/services/NFeRecepcaoEvento4', Nfe::Sefaz::Webservices.url('MG', :producao, :evento)
    assert_equal 'https://homologacao.nfe.fazenda.sp.gov.br/ws/nferecepcaoevento4.asmx', Nfe::Sefaz::Webservices.url('SP', :homologacao, :evento)
    assert_equal 'https://nfe.svrs.rs.gov.br/ws/recepcaoevento/recepcaoevento4.asmx', Nfe::Sefaz::Webservices.url('RJ', :producao, :evento)
  end
end
