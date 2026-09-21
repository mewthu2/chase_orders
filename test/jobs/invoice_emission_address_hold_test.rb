require 'test_helper'
require 'webmock/minitest'

# Quando o Tiny recusa a nota por endereço e o Honey já tem a correção, o pedido fica aguardando a
# correção da nota no Tiny (a API não permite alterar a nota) em vez de repetir o erro a cada execução.
class InvoiceEmissionAddressHoldTest < ActiveSupport::TestCase
  EMIT_URL = 'https://api.tiny.com.br/api2/nota.fiscal.emitir.php'.freeze
  BAIRRO_ERROR = 'A nota fiscal não foi enviada, pois contêm erros O campo "Bairro" não foi preenchido ou está inválido'.freeze

  JOBS = {
    b2c: { job: InvoiceEmitionsJob, created: :create_correios_order, emitted: :emission_invoice, token: 'TOKEN_TINY3_PRODUCTION' },
    b2b: { job: InvoiceEmitionsJob2, created: :create_correios_order_tiny2, emitted: :emission_invoice_tiny2, token: 'TOKEN_TINY2_PRODUCTION' }
  }.freeze

  def setup
    ENV['EMITIR_NOTA_FISCAL'] = EMIT_URL
    ENV['TOKEN_TINY3_PRODUCTION'] = 'token-tiny3'
    ENV['TOKEN_TINY2_PRODUCTION'] = 'token-tiny2'
    ENV['TINY_NOTA_FISCAL_URL'] = 'https://erp.tiny.com.br/notas_fiscais#edit/'
  end

  def xml_error(message)
    "<retorno><status_processamento>2</status_processamento><status>Erro</status><erros><erro>#{message}</erro></erros></retorno>"
  end

  def xml_ok
    '<retorno><status_processamento>3</status_processamento><status>OK</status></retorno>'
  end

  def stub_emit(body)
    stub_request(:get, EMIT_URL).with(query: hash_including('formato' => 'string')).to_return(body: body)
  end

  def create_step(kind, tiny_order_id: 919_948_777, invoice_id: 919_948_778)
    Attempt.create!(kinds: JOBS[kind][:created], status: :success, tiny_order_id: tiny_order_id, id_nota_fiscal: invoice_id, order_correios_id: 25_010_473)
  end

  def correction(overrides = {})
    AddressCorrection.create!({ tiny_order_id: '919948777', endereco: 'Rua A', numero: '543', bairro: 'Centro', cep: '89.874-000', cidade: 'Maravilha', uf: 'SC' }.merge(overrides))
  end

  def emission_attempts(kind, tiny_order_id = 919_948_777)
    Attempt.where(kinds: JOBS[kind][:emitted], tiny_order_id: tiny_order_id)
  end

  JOBS.each_key do |kind|
    test "[#{kind}] an address error with a correction puts the order on hold with a message telling what to type in Tiny" do
      record = correction
      step = create_step(kind)
      stub_emit(xml_error(BAIRRO_ERROR))

      attempt = JOBS[kind][:job].new.one_emission(step)

      assert attempt.error?
      assert_match(/Bairro/, attempt.message)
      assert_match(/Centro/, attempt.message)
      assert_includes attempt.message, 'https://erp.tiny.com.br/notas_fiscais#edit/919948778'
      assert_match(/Já corrigi no Tiny/, attempt.message)
      assert record.reload.awaiting_tiny_fix?
      assert_match(/Bairro/, record.awaiting_tiny_fix_message)
    end

    test "[#{kind}] the automatic run skips an order on hold: no Tiny call and no new attempt" do
      correction.hold!('Bairro')
      create_step(kind)
      stub = stub_emit(xml_ok)

      assert_no_difference -> { emission_attempts(kind).count } do
        JOBS[kind][:job].new.all_emissions
      end
      assert_not_requested stub
    end

    test "[#{kind}] the automatic run still emits the other orders" do
      correction.hold!('Bairro')
      create_step(kind)
      create_step(kind, tiny_order_id: 111, invoice_id: 222)
      stub = stub_emit(xml_ok)

      JOBS[kind][:job].new.all_emissions

      assert_requested stub, times: 1
      assert_equal 1, emission_attempts(kind, 111).count
      assert_equal 0, emission_attempts(kind).count
    end

    test "[#{kind}] a manual emission ignores the hold, and a success releases it" do
      record = correction
      record.hold!('Bairro')
      step = create_step(kind)
      stub_emit(xml_ok)

      attempt = JOBS[kind][:job].new.one_emission(step)

      assert attempt.success?
      refute record.reload.awaiting_tiny_fix?
      assert_not_nil record.tiny_fixed_at
    end

    test "[#{kind}] without a correction nothing is put on hold and the message stays as before" do
      step = create_step(kind)
      stub_emit(xml_error(BAIRRO_ERROR))

      attempt = JOBS[kind][:job].new.one_emission(step)

      assert attempt.error?
      assert_equal BAIRRO_ERROR.first(100), attempt.message
      assert_empty AddressCorrection.awaiting_tiny_fix
    end

    test "[#{kind}] an error that is not about the address does not put the order on hold" do
      record = correction
      step = create_step(kind)
      stub_emit(xml_error('A nota fiscal não foi enviada, pois contêm erros O campo "CFOP" não foi preenchido'))

      attempt = JOBS[kind][:job].new.one_emission(step)

      assert attempt.error?
      refute record.reload.awaiting_tiny_fix?
    end

    test "[#{kind}] a correction with no value for the failing field does not put the order on hold" do
      record = correction(bairro: '')
      step = create_step(kind)
      stub_emit(xml_error(BAIRRO_ERROR))

      JOBS[kind][:job].new.one_emission(step)

      refute record.reload.awaiting_tiny_fix?
    end

    test "[#{kind}] other address fields (Cidade) also hold, with that field in the hint" do
      record = correction
      step = create_step(kind)
      stub_emit(xml_error('A nota fiscal não foi enviada, pois contêm erros O campo "Cidade" não foi preenchido ou está inválido'))

      attempt = JOBS[kind][:job].new.one_emission(step)

      assert record.reload.awaiting_tiny_fix?
      assert_match(/Cidade.*Maravilha/, attempt.message)
    end
  end
end
