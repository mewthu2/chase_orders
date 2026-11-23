require 'test_helper'
require_relative '../../support/shopify_order_factory'
require_relative '../../support/nfe_company_factory'

# Carta de correção da NF-e na SEFAZ (evento 110110) e o PDF dela (DACCE).
class Nfe::CorrectionLetterTest < ActiveSupport::TestCase
  include NfeCompanyFactory
  NFE_NS = 'http://www.portalfiscal.inf.br/nfe'.freeze
  NS = { 'n' => NFE_NS, 'ds' => 'http://www.w3.org/2000/09/xmldsig#' }.freeze
  TEXT = 'Onde se le Rua A, 10, leia-se Rua A, 100, apto 201.'.freeze

  class FakeClient
    attr_reader :calls

    def initialize(*responses)
      @responses = responses
      @calls = []
    end

    def event(signed, batch_id:)
      @calls << [signed, batch_id]
      response = @responses.size > 1 ? @responses.shift : @responses.first
      raise response if response.is_a?(Exception)

      Nokogiri::XML(response.call(Nokogiri::XML(signed)))
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
    @user = User.create!(name: 'Fiscal', email: 'fiscal_cce@example.com', password: 'password123')
  end

  # Resposta da SEFAZ que ecoa a sequência do evento enviado.
  def answer(code, message, batch: '128')
    lambda do |event|
      seq = event.at_xpath('//n:nSeqEvento', NS).text
      "<retEnvEvento xmlns=\"#{NFE_NS}\" versao=\"1.00\"><idLote>1</idLote><tpAmb>2</tpAmb><verAplic>MG</verAplic><cOrgao>31</cOrgao>" \
        "<cStat>#{batch}</cStat><xMotivo>Lote de evento processado</xMotivo>" \
        "<retEvento versao=\"1.00\"><infEvento><tpAmb>2</tpAmb><verAplic>MG</verAplic><cOrgao>31</cOrgao><cStat>#{code}</cStat>" \
        "<xMotivo>#{message}</xMotivo><chNFe>#{@note.access_key}</chNFe><tpEvento>110110</tpEvento><nSeqEvento>#{seq}</nSeqEvento>" \
        "<dhRegEvento>2026-11-23T10:00:00-03:00</dhRegEvento><nProt>13126000000099#{seq}</nProt></infEvento></retEvento></retEnvEvento>"
    end
  end

  def correct(client, text: TEXT)
    Nfe::CorrectionLetter.call(@note, text: text, user: @user, client: client)
  end

  test 'sends the signed 110110 event in the Receita layout and records the letter with the procEventoNFe' do
    client = FakeClient.new(answer('135', 'Evento registrado e vinculado a NF-e'))

    correction = correct(client, text: "  Onde se lê “Rua A, 10” — leia-se\n Rua A, 100, apto 201.  ")

    event = Nokogiri::XML(client.calls.first[0])
    info = event.at_xpath('//n:infEvento', NS)
    assert_equal "ID110110#{@note.access_key}01", info['Id']
    assert_equal %w[cOrgao tpAmb CNPJ chNFe dhEvento tpEvento nSeqEvento verEvento detEvento], info.element_children.map(&:name)
    assert_equal ['31', '2', '110110', '1', '1.00'], %w[cOrgao tpAmb tpEvento nSeqEvento verEvento].map { |t| info.at_xpath("n:#{t}", NS).text }
    detail = info.at_xpath('n:detEvento', NS)
    assert_equal '1.00', detail['versao']
    assert_equal %w[descEvento xCorrecao xCondUso], detail.element_children.map(&:name)
    assert_equal 'Carta de Correcao', detail.at_xpath('n:descEvento', NS).text
    assert_equal 'Onde se lê "Rua A, 10" - leia-se Rua A, 100, apto 201.', detail.at_xpath('n:xCorrecao', NS).text
    assert_equal Nfe::CorrectionLetter::CONDITIONS_OF_USE, detail.at_xpath('n:xCondUso', NS).text
    assert_match(/\AA Carta de Correcao e disciplinada pelo paragrafo 1o-A do art\. 7o do Convenio S\/N.*III - a data de emissao ou de saida\.\z/,
                 Nfe::CorrectionLetter::CONDITIONS_OF_USE)
    assert_equal "#ID110110#{@note.access_key}01", event.at_xpath('//ds:Reference', NS)['URI']

    assert_equal [1, '131260000000991', 'Fiscal', '135'], [correction.sequence, correction.protocol, correction.created_by, correction.sefaz_status_code]
    assert @note.reload.autorizada?, 'a carta não muda a situação da nota'
    proc_event = Nokogiri::XML(correction.xml.download)
    assert proc_event.at_xpath('/n:procEventoNFe/n:evento/ds:Signature', NS)
    assert_equal '135', proc_event.at_xpath('/n:procEventoNFe/n:retEvento/n:infEvento/n:cStat', NS).text
  end

  test 'each new letter takes the next sequence and replaces the previous one' do
    client = FakeClient.new(answer('135', 'ok'))

    correct(client)
    second = correct(client, text: "#{TEXT} Volumes: 2.")

    assert_equal 2, second.sequence
    assert_equal "ID110110#{@note.access_key}02", Nokogiri::XML(client.calls.last[0]).at_xpath('//n:infEvento', NS)['Id']
    assert_equal [1, 2], @note.corrections.reload.map(&:sequence)
    assert second.current?
    assert_not @note.corrections.first.current?
  end

  test 'a refused letter records nothing and shows the SEFAZ reason' do
    error = assert_raises(Nfe::CorrectionLetter::Error) { correct(FakeClient.new(answer('573', 'Rejeicao: Duplicidade de evento'))) }

    assert_match(/573 Rejeicao: Duplicidade de evento/, error.message)
    assert_empty @note.corrections.reload
  end

  test 'validates text size, the note status and the 20 letters limit before calling SEFAZ' do
    client = FakeClient.new(answer('135', 'ok'))

    assert_raises(Nfe::CorrectionLetter::Error) { correct(client, text: 'curto demais') }
    assert_raises(Nfe::CorrectionLetter::Error) { correct(client, text: 'x' * 1001) }
    20.times { |i| @note.corrections.create!(sequence: i + 1, correction: TEXT) }
    error = assert_raises(Nfe::CorrectionLetter::Error) { correct(client) }
    assert_match(/20 cartas/, error.message)
    assert_not @note.reload.correctable?
    @note.corrections.destroy_all
    @note.update!(status: :cancelada)
    error = assert_raises(Nfe::CorrectionLetter::Error) { correct(client) }
    assert_match(/Só nota autorizada/, error.message)
    assert_empty client.calls
  end

  test 'a communication failure is reported and nothing is recorded' do
    error = assert_raises(Nfe::CorrectionLetter::Error) { correct(FakeClient.new(Nfe::Sefaz::Client::Error.new('timeout'))) }

    assert_match(/timeout/, error.message)
    assert_empty @note.corrections.reload
  end

  test 'the DACCE PDF renders from the event and the note XML' do
    correction = correct(FakeClient.new(answer('135', 'ok')))
    pdf = Nfe::CorrectionLetterPdf.new(correction.xml.download, @note.xml.download)

    body = pdf.render
    assert body.start_with?('%PDF')
    assert_equal "CCe-#{@note.access_key}-01.pdf", pdf.filename
    assert Nfe::CorrectionLetterPdf.new(correction.xml.download, nil).render.start_with?('%PDF'), 'sem o XML da nota também sai'
  end
end
