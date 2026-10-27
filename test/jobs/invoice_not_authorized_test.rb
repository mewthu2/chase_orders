require 'test_helper'
require 'webmock/minitest'

# O Tiny responde "apenas notas pendentes ou rejeitadas podem ser enviadas" também para notas em
# processamento na SEFAZ, que podem voltar para pendente. A emissão era gravada como sucesso e o
# pedido ficava preso no envio de XML ("Nenhuma tag prod"), que recebia "Nota Fiscal não autorizada".
class InvoiceNotAuthorizedTest < ActiveSupport::TestCase
  EMIT_URL = 'https://api.tiny.com.br/api2/nota.fiscal.emitir.php'.freeze
  OBTAIN_URL = 'https://api.tiny.com.br/api2/nota.fiscal.obter.php'.freeze
  XML_URL = 'https://api.tiny.com.br/api2/nota.fiscal.obter.xml.php'.freeze
  ALREADY_SENT = 'Nota Fiscal localizada, porém apenas notas pendentes ou rejeitadas podem ser enviadas'.freeze

  FLOWS = {
    b2c: { emit_job: InvoiceEmitionsJob, xml_job: SendXmlCorreiosLogJob, created: :create_correios_order,
           emitted: :emission_invoice, sent: :send_xml, token: 'token-tiny3' },
    b2b: { emit_job: InvoiceEmitionsJob2, xml_job: SendXmlCorreiosLogJob2, created: :create_correios_order_tiny2,
           emitted: :emission_invoice_tiny2, sent: :send_xml_tiny2, token: 'token-tiny2' }
  }.freeze

  def setup
    ENV['EMITIR_NOTA_FISCAL'] = EMIT_URL
    ENV['OBTER_NOTA_FISCAL'] = OBTAIN_URL
    ENV['OBTER_XML_NOTA_FISCAL'] = XML_URL
    ENV['TOKEN_TINY3_PRODUCTION'] = 'token-tiny3'
    ENV['TOKEN_TINY2_PRODUCTION'] = 'token-tiny2'
  end

  def create_step(flow)
    Attempt.create!(kinds: FLOWS[flow][:created], status: :success, tiny_order_id: 920_345_680,
                    id_nota_fiscal: 920_345_681, order_correios_id: 25_199_698)
  end

  def tiny_error(message)
    "<retorno><status_processamento>2</status_processamento><status>Erro</status><erros><erro>#{message}</erro></erros></retorno>"
  end

  def stub_emit_already_sent
    stub_request(:get, EMIT_URL).with(query: hash_including('id' => '920345681')).to_return(body: tiny_error(ALREADY_SENT))
  end

  def stub_situation(flow, code, description)
    stub_request(:get, OBTAIN_URL)
      .with(query: hash_including('id' => '920345681', 'token' => FLOWS[flow][:token]))
      .to_return(body: { retorno: { status: 'OK', nota_fiscal: { situacao: code, descricao_situacao: description } } }.to_json)
  end

  FLOWS.each_key do |flow|
    test "[#{flow}] a nota still pending in Tiny is not counted as emitted" do
      stub_emit_already_sent
      stub_situation(flow, '1', 'Pendente')

      attempt = FLOWS[flow][:emit_job].new.one_emission(create_step(flow))

      assert attempt.error?
      assert_equal 'Nota ainda não autorizada no Tiny (situação: Pendente)', attempt.message
    end

    test "[#{flow}] an authorized nota is counted as emitted" do
      stub_emit_already_sent
      stub_situation(flow, '6', 'Autorizada')

      attempt = FLOWS[flow][:emit_job].new.one_emission(create_step(flow))

      assert attempt.success?
    end

    test "[#{flow}] a nota not authorized when sending the XML goes back to the emission queue" do
      step = create_step(flow)
      Attempt.create!(kinds: FLOWS[flow][:emitted], status: :success, tiny_order_id: 920_345_680,
                      id_nota_fiscal: 920_345_681, order_correios_id: 25_199_698)
      stub_request(:get, XML_URL).with(query: hash_including('id' => '920345681'))
                                 .to_return(body: tiny_error('Nota Fiscal não autorizada'))

      attempt = FLOWS[flow][:xml_job].new.send_one_xml(step)

      assert attempt.error?
      assert_equal 'Tiny: Nota Fiscal não autorizada (nota 920345681)', attempt.error
      assert_empty Attempt.where(kinds: FLOWS[flow][:emitted], status: :success)
    end

    test "[#{flow}] other Tiny errors when sending the XML keep the emission" do
      step = create_step(flow)
      Attempt.create!(kinds: FLOWS[flow][:emitted], status: :success, tiny_order_id: 920_345_680,
                      id_nota_fiscal: 920_345_681, order_correios_id: 25_199_698)
      stub_request(:get, XML_URL).with(query: hash_including('id' => '920345681'))
                                 .to_return(body: tiny_error('API Bloqueada - Excedido o número de acessos a API'))

      attempt = FLOWS[flow][:xml_job].new.send_one_xml(step)

      assert attempt.error?
      assert_match(/API Bloqueada/, attempt.error)
      assert_equal 1, Attempt.where(kinds: FLOWS[flow][:emitted], status: :success).count
    end
  end
end
