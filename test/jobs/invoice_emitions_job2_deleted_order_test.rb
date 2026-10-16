require 'test_helper'
require 'webmock/minitest'

# Pedido excluído no Tiny (em geral refeito com outro número): a nota some junto e a emissão
# respondia "Nota Fiscal não localizada" a cada execução, prendendo o pedido na fila para sempre.
class InvoiceEmitionsJob2DeletedOrderTest < ActiveSupport::TestCase
  EMIT_URL = 'https://api.tiny.com.br/api2/nota.fiscal.emitir.php'.freeze
  ORDER_URL = 'https://api.tiny.com.br/api2/pedido.obter.php'.freeze
  NOT_FOUND = 'Nota Fiscal não localizada, apenas notas pendentes ou rejeitadas podem ser enviadas'.freeze

  def setup
    ENV['EMITIR_NOTA_FISCAL'] = EMIT_URL
    ENV['TOKEN_TINY2_PRODUCTION'] = 'token-tiny2'
    stub_request(:get, EMIT_URL).with(query: hash_including('formato' => 'string')).to_return(
      body: "<retorno><status_processamento>2</status_processamento><status>Erro</status><erros><erro>#{NOT_FOUND}</erro></erros></retorno>"
    )
    @step = Attempt.create!(kinds: :create_correios_order_tiny2, status: :success, tiny_order_id: 902_483_693,
                            id_nota_fiscal: 902_487_256, order_correios_id: 25_122_316)
  end

  def stub_order(body)
    stub_request(:get, ORDER_URL).with(query: hash_including('id' => '902483693')).to_return(body: body.to_json)
  end

  def queue
    successful = Attempt.where(kinds: :emission_invoice_tiny2, status: :success).pluck(:order_correios_id).compact
    Attempt.where(kinds: :create_correios_order_tiny2, status: :success).where.not(order_correios_id: successful)
  end

  test 'an order deleted in Tiny leaves the emission queue' do
    stub_order(retorno: { status: 'Erro', codigo_erro: '20', erros: [{ erro: 'Pedido não localizado' }] })

    attempt = InvoiceEmitionsJob2.new.one_emission(@step)

    assert attempt.error?
    assert_match(/excluído no Tiny/, attempt.message)
    assert @step.reload.fail?
    assert_empty queue
  end

  test 'a missing nota of an order that still exists in Tiny stays in the queue' do
    stub_order(retorno: { status: 'OK', pedido: { id: '902483693', numero: '1333' } })

    InvoiceEmitionsJob2.new.one_emission(@step)

    assert @step.reload.success?
    assert_equal [@step], queue.to_a
  end

  test 'when Tiny cannot be reached the order stays in the queue' do
    stub_request(:get, ORDER_URL).with(query: hash_including('id' => '902483693')).to_timeout

    InvoiceEmitionsJob2.new.one_emission(@step)

    assert @step.reload.success?
  end
end
