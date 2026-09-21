require 'test_helper'
require 'webmock/minitest'

class DashboardAddressCorrectionTest < ActionDispatch::IntegrationTest
  def setup
    ENV['TINY_SELLS_URL'] = 'https://erp.tiny.com.br/vendas'
    @admin = User.create!(name: 'Admin Dashboard', email: 'admin_dash_ac@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    sign_in @admin
  end

  def created_step(kind, tiny_order_id, order_correios_id)
    Attempt.create!(kinds: kind, status: :success, tiny_order_id: tiny_order_id, id_nota_fiscal: tiny_order_id + 1, order_correios_id: order_correios_id)
  end

  def correction(tiny_order_id, held: false)
    record = AddressCorrection.create!(tiny_order_id: tiny_order_id.to_s, endereco: 'Rua A', numero: '1', bairro: 'Centro', cidade: 'Maravilha', uf: 'SC')
    record.hold!('A nota fiscal não foi enviada, pois contêm erros O campo "Bairro" não foi preenchido ou está inválido') if held
    record
  end

  test 'the B2C invoice screen marks orders with a correction and orders waiting for the Tiny fix' do
    created_step(:create_correios_order, 100, 1)
    created_step(:create_correios_order, 200, 2)
    created_step(:create_correios_order, 300, 3)
    correction(100)
    correction(200, held: true)

    get invoice_emition_dashboard_index_path

    assert_response :success
    assert_select '.address-correction-badge', text: /Endereço corrigido/, count: 1
    assert_select '.address-correction-badge', text: /Aguardando correção da nota no Tiny/, count: 1
  end

  test 'the B2B invoice screen marks them too' do
    created_step(:create_correios_order_tiny2, 100, 1)
    created_step(:create_correios_order_tiny2, 200, 2)
    correction(100)
    correction(200, held: true)

    get invoice_emition_b2b_dashboard_index_path

    assert_response :success
    assert_select '.address-correction-badge', text: /Endereço corrigido/, count: 1
    assert_select '.address-correction-badge', text: /Aguardando correção da nota no Tiny/, count: 1
  end

  test 'the invoice screens do not query corrections once per row' do
    6.times { |n| created_step(:create_correios_order, 1000 + n, 10 + n) }
    correction(1000)
    count = 0
    counter = ->(*, payload) { count += 1 if payload[:sql].match?(/FROM `address_corrections`/) }

    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') { get invoice_emition_dashboard_index_path }

    assert_operator count, :<=, 1
  end

  # ---- pipeline (relatório em cache no Redis) ----

  class FakeRedis
    def initialize(payload) = @payload = payload
    def get(_key) = @payload.to_json
    def set(*) = true
  end

  test 'the pipeline attention rows carry the correction status for the screen to badge' do
    correction(100)
    correction(200, held: true)
    payload = { counts: { invoice: 1 }, attention: [
      { tiny_order_id: 100, current_stage: 'invoice', reason: 'error', message: 'x' },
      { tiny_order_id: 200, current_stage: 'invoice', reason: 'error', message: 'y' },
      { tiny_order_id: 300, current_stage: 'invoice', reason: 'error', message: 'z' }
    ] }
    original = $redis
    $redis = FakeRedis.new(payload)

    get correios_pipeline_dashboard_index_path(format: :json)
    rows = JSON.parse(response.body)['attention']

    assert_equal 'corrected', rows.find { |r| r['tiny_order_id'] == 100 }['address_correction']
    assert_equal 'awaiting', rows.find { |r| r['tiny_order_id'] == 200 }['address_correction']
    assert_nil rows.find { |r| r['tiny_order_id'] == 300 }['address_correction']
  ensure
    $redis = original
  end

  test 'the pipeline screen template renders the correction badge' do
    get correios_pipeline_dashboard_index_path

    assert_response :success
    assert_match(/address_correction/, response.body)
    assert_match(/Aguardando correção da nota no Tiny/, response.body)
  end

  # ---- correção dentro da própria tela de emissão ----

  EMIT_URL = 'https://api.tiny.com.br/api2/nota.fiscal.emitir.php'.freeze

  test 'a row waiting for the Tiny fix shows what to type, the invoice link and the button, right on the emission screen' do
    step = created_step(:create_correios_order, 100, 1)
    created_step(:create_correios_order, 200, 2)
    correction(100, held: true)
    correction(200)

    get invoice_emition_dashboard_index_path

    assert_select '.address-hold-actions', count: 1
    assert_select '.address-hold-actions', text: /Bairro.*Centro/m
    assert_select ".address-hold-actions a[href='https://erp.tiny.com.br/notas_fiscais#edit/#{step.id_nota_fiscal}']"
    assert_select ".address-hold-actions form[action='#{mark_tiny_fixed_attempts_path}'] input[name=tiny_order_id][value='100']"
    assert_select ".address-hold-actions form input[name=return_to][value=invoice_emition]"
    assert_select ".address-hold-actions form", text: /Já corrigi no Tiny/
  end

  test 'the B2B emission screen has the same in-place correction' do
    step = created_step(:create_correios_order_tiny2, 100, 1)
    correction(100, held: true)

    get invoice_emition_b2b_dashboard_index_path

    assert_select ".address-hold-actions a[href='https://erp.tiny.com.br/notas_fiscais#edit/#{step.id_nota_fiscal}']"
    assert_select ".address-hold-actions form input[name=return_to][value=invoice_emition_b2b]"
  end

  test 'orders that are not waiting have no correction box' do
    created_step(:create_correios_order, 100, 1)
    correction(100)

    get invoice_emition_dashboard_index_path

    assert_select '.address-hold-actions', count: 0
  end

  test 'run now returns the Tiny fix data for an address error so the modal can link to the invoice' do
    ENV['EMITIR_NOTA_FISCAL'] = EMIT_URL
    ENV['TOKEN_TINY3_PRODUCTION'] = 'token-tiny3'
    step = created_step(:create_correios_order, 100, 1)
    correction(100)
    stub_request(:get, EMIT_URL).with(query: hash_including('formato' => 'string')).to_return(
      body: '<retorno><status>Erro</status><erros><erro>A nota fiscal não foi enviada, pois contêm erros O campo "Bairro" não foi preenchido ou está inválido</erro></erros></retorno>'
    )

    post run_invoice_emition_now_dashboard_index_path, params: { attempt_id: step.id }, as: :json
    json = JSON.parse(response.body)

    assert_equal false, json['success']
    assert_equal 'https://erp.tiny.com.br/notas_fiscais#edit/101', json['tiny_fix']['nota_url']
    assert_match(/Bairro.*Centro/, json['tiny_fix']['instructions'])
  end

  test 'run now has no Tiny fix data when the order is not waiting' do
    ENV['EMITIR_NOTA_FISCAL'] = EMIT_URL
    ENV['TOKEN_TINY3_PRODUCTION'] = 'token-tiny3'
    step = created_step(:create_correios_order, 100, 1)
    stub_request(:get, EMIT_URL).with(query: hash_including('formato' => 'string')).to_return(body: '<retorno><status>OK</status></retorno>')

    post run_invoice_emition_now_dashboard_index_path, params: { attempt_id: step.id }, as: :json

    assert_nil JSON.parse(response.body)['tiny_fix']
  end

  test 'the emission screens include the modal script that shows the Tiny fix link' do
    get invoice_emition_dashboard_index_path

    assert_includes response.body, 'data.tiny_fix'
  end
end
