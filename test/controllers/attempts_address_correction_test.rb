require 'test_helper'
require 'webmock/minitest'

class AttemptsAddressCorrectionTest < ActionDispatch::IntegrationTest
  EMIT_URL = 'https://api.tiny.com.br/api2/nota.fiscal.emitir.php'.freeze
  ORDER_ID = 919_948_777
  BAIRRO_ERROR = 'A nota fiscal não foi enviada, pois contêm erros O campo "Bairro" não foi preenchido ou está inválido'.freeze

  def setup
    ENV['EMITIR_NOTA_FISCAL'] = EMIT_URL
    ENV['TOKEN_TINY3_PRODUCTION'] = 'token-tiny3'
    ENV['TOKEN_TINY2_PRODUCTION'] = 'token-tiny2'
    ENV['TINY_NOTA_FISCAL_URL'] = 'https://erp.tiny.com.br/notas_fiscais#edit/'
    ENV['TINY_SELLS_URL'] = 'https://erp.tiny.com.br/vendas'
    @admin = User.create!(name: 'Admin Tentativas', email: 'admin_attempts_ac@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    sign_in @admin
  end

  def correction(overrides = {})
    AddressCorrection.create!({ tiny_order_id: ORDER_ID.to_s, endereco: 'Rua Prefeito Albino Cerutti Cella', numero: '543',
                                bairro: 'Centro', cep: '89.874-000', cidade: 'Maravilha', uf: 'SC' }.merge(overrides))
  end

  def emission_attempt(kind: :emission_invoice, message: BAIRRO_ERROR, order_id: ORDER_ID)
    Attempt.create!(kinds: kind, status: :error, tiny_order_id: order_id, id_nota_fiscal: 919_948_778, order_correios_id: 25_010_473, message: message)
  end

  def xml_error(message)
    "<retorno><status>Erro</status><erros><erro>#{message}</erro></erros></retorno>"
  end

  def stub_emit(body)
    stub_request(:get, EMIT_URL).with(query: hash_including('formato' => 'string')).to_return(body: body)
  end

  # ---- item 1: aviso ----

  test 'verify_attempts shows the correction and a note that it only covers what Honey sends' do
    correction
    emission_attempt

    get verify_attempts_attempts_path(tiny_order_id: ORDER_ID)

    assert_response :success
    assert_select '.address-correction-banner', text: /Endereço corrigido no Honey/
    assert_select '.address-correction-banner', text: /Centro/
    assert_select '.address-correction-banner', text: /Maravilha\/SC/
  end

  test 'a held order shows what to type in Tiny, the link to the invoice and the button' do
    correction.hold!(BAIRRO_ERROR)
    emission_attempt

    get verify_attempts_attempts_path(tiny_order_id: ORDER_ID)

    assert_select '.address-correction-banner', text: /Aguardando correção da nota no Tiny/
    assert_select ".address-correction-banner a[href='https://erp.tiny.com.br/notas_fiscais#edit/919948778']"
    assert_select "form[action='#{mark_tiny_fixed_attempts_path}'] input[name=tiny_order_id][value='#{ORDER_ID}']"
    assert_select "form[action='#{mark_tiny_fixed_attempts_path}']", text: /Já corrigi no Tiny/
  end

  test 'without a correction there is no banner' do
    emission_attempt

    get verify_attempts_attempts_path(tiny_order_id: ORDER_ID)

    assert_select '.address-correction-banner', count: 0
  end

  test 'the rows of orders with a correction get a badge on verify_attempts and on the index' do
    correction
    emission_attempt
    other = emission_attempt(order_id: 111)

    get verify_attempts_attempts_path(tiny_order_id: ORDER_ID)
    assert_select '.address-correction-badge', text: /Endereço corrigido/, minimum: 1

    get attempts_path
    assert_select '.address-correction-badge', text: /Endereço corrigido/, count: 1
    assert other.persisted?
  end

  test 'a held order shows the waiting badge on the index' do
    correction.hold!('x')
    emission_attempt

    get attempts_path

    assert_select '.address-correction-badge', text: /Aguardando correção da nota no Tiny/
  end

  test 'the index does not query corrections once per attempt' do
    correction
    6.times { |n| emission_attempt(order_id: 100 + n) }
    count = 0
    counter = ->(*, payload) { count += 1 if payload[:sql].match?(/FROM `address_corrections`/) }

    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') { get attempts_path }

    assert_operator count, :<=, 1
  end

  # ---- item 4: "Já corrigi no Tiny" ----

  test 'marking as fixed releases the hold and emits the invoice again; a success is reported' do
    record = correction
    record.hold!(BAIRRO_ERROR)
    emission_attempt
    stub = stub_emit('<retorno><status>OK</status></retorno>')

    assert_difference -> { Attempt.where(kinds: :emission_invoice, status: :success).count }, 1 do
      post mark_tiny_fixed_attempts_path, params: { tiny_order_id: ORDER_ID }
    end

    assert_requested stub
    refute record.reload.awaiting_tiny_fix?
    assert_redirected_to verify_attempts_attempts_path(tiny_order_id: ORDER_ID)
    follow_redirect!
    assert_select '.flash-messages-container .alert-success', text: /Nota enviada/
  end

  test 'if Tiny still refuses the address the order goes back on hold and the message says so' do
    record = correction
    record.hold!(BAIRRO_ERROR)
    emission_attempt
    stub_emit(xml_error(BAIRRO_ERROR))

    post mark_tiny_fixed_attempts_path, params: { tiny_order_id: ORDER_ID }

    assert record.reload.awaiting_tiny_fix?
    follow_redirect!
    assert_select '.flash-messages-container .alert-danger', text: /ainda recusou.*Bairro/m
  end

  test 'another kind of error after the fix is reported and the hold stays released' do
    record = correction
    record.hold!(BAIRRO_ERROR)
    emission_attempt
    stub_emit(xml_error('Certificado digital vencido'))

    post mark_tiny_fixed_attempts_path, params: { tiny_order_id: ORDER_ID }

    refute record.reload.awaiting_tiny_fix?
    follow_redirect!
    assert_select '.flash-messages-container .alert-danger', text: /Certificado digital vencido/
  end

  test 'B2B orders are emitted with the Tiny 2 account' do
    record = correction
    record.hold!(BAIRRO_ERROR)
    emission_attempt(kind: :emission_invoice_tiny2)
    stub = stub_request(:get, EMIT_URL).with(query: hash_including('token' => 'token-tiny2')).to_return(body: '<retorno><status>OK</status></retorno>')

    post mark_tiny_fixed_attempts_path, params: { tiny_order_id: ORDER_ID }

    assert_requested stub
    assert_equal 1, Attempt.where(kinds: :emission_invoice_tiny2, status: :success).count
  end

  test 'without any emission attempt it just releases the hold and says the automatic run will try again' do
    record = correction
    record.hold!(BAIRRO_ERROR)
    stub = stub_emit('<retorno><status>OK</status></retorno>')

    post mark_tiny_fixed_attempts_path, params: { tiny_order_id: ORDER_ID }

    refute record.reload.awaiting_tiny_fix?
    assert_not_requested stub
    follow_redirect!
    assert_select '.flash-messages-container .alert', text: /emissão automática/
  end

  test 'marking as fixed from the emission screen goes back to it, not to the history' do
    record = correction
    record.hold!(BAIRRO_ERROR)
    emission_attempt
    stub_emit('<retorno><status>OK</status></retorno>')

    post mark_tiny_fixed_attempts_path, params: { tiny_order_id: ORDER_ID, return_to: 'invoice_emition' }

    assert_redirected_to invoice_emition_dashboard_index_path
  end

  test 'the B2B emission screen is also a valid place to return to' do
    correction.hold!(BAIRRO_ERROR)
    emission_attempt(kind: :emission_invoice_tiny2)
    stub_emit('<retorno><status>OK</status></retorno>')

    post mark_tiny_fixed_attempts_path, params: { tiny_order_id: ORDER_ID, return_to: 'invoice_emition_b2b' }

    assert_redirected_to invoice_emition_b2b_dashboard_index_path
  end

  test 'an unknown return_to is ignored (no open redirect)' do
    correction.hold!(BAIRRO_ERROR)
    emission_attempt
    stub_emit('<retorno><status>OK</status></retorno>')

    post mark_tiny_fixed_attempts_path, params: { tiny_order_id: ORDER_ID, return_to: 'https://evil.example.com' }

    assert_redirected_to verify_attempts_attempts_path(tiny_order_id: ORDER_ID)
  end

  test 'an order without a correction cannot be marked as fixed' do
    post mark_tiny_fixed_attempts_path, params: { tiny_order_id: ORDER_ID }

    assert_redirected_to verify_attempts_attempts_path(tiny_order_id: ORDER_ID)
    follow_redirect!
    assert_select '.flash-messages-container .alert-danger', text: /correção de endereço/i
  end

  test 'an order that is not on hold is not re-emitted by mistake' do
    correction
    emission_attempt
    stub = stub_emit('<retorno><status>OK</status></retorno>')

    post mark_tiny_fixed_attempts_path, params: { tiny_order_id: ORDER_ID }

    assert_not_requested stub
    follow_redirect!
    assert_select '.flash-messages-container .alert', text: /não está aguardando/
  end
end
