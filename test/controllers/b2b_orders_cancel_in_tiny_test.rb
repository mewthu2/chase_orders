require 'test_helper'
require 'webmock/minitest'

class B2bOrdersCancelInTinyTest < ActionDispatch::IntegrationTest
  STATUS_URL = 'https://api.tiny.com.br/api2/pedido.alterar.situacao.php'.freeze
  PEDIDO_URL = 'https://api.tiny.com.br/api2/pedido.incluir.php'.freeze

  def setup
    ENV['TOKEN_TINY2_PRODUCTION'] = 'fake-token-tiny2'
    @admin = User.create!(name: 'Admin Cancel', email: 'admin_cancel@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @client = Client.create!(responsible_name: 'Cliente Cancel', registration: '25.405.327/0001-74')
    @location = TransferLocation.create!(
      name: 'CD Cancel', registration: '25.405.327/0001-74', street: 'Rua A', number: '10',
      neighbourhood: 'Bairro', city: 'BH', state: 'MG', zip: '30000-000'
    )
    sign_in @admin
    # Por padrão o pedido existe no Tiny (consultado quando o cancelamento é recusado).
    stub_request(:get, 'https://api.tiny.com.br/api2/pedido.obter.php').with(query: hash_including('formato' => 'json'))
      .to_return(body: { retorno: { status: 'OK', pedido: { id: '555', situacao: 'Faturado' } } }.to_json)
  end

  def build_order(kind: :sale, **attrs)
    target = kind == :sale ? { client: @client } : { transfer_location: @location, price_list: :transfer }
    order = B2bOrder.new({ kind: kind, user: @admin, status: :aprovado }.merge(target).merge(attrs))
    order.b2b_order_items.build(sku: 'SKU1', name: 'Produto', quantity: 1, price: 10)
    order.save!
    order
  end

  def sent_order(**attrs)
    build_order(tiny_reference_id: '555', tiny_reference_number: '1900', **attrs)
  end

  def stub_status_ok
    stub_request(:post, STATUS_URL).with(body: hash_including('id' => '555', 'situacao' => 'cancelado'))
                                   .to_return(body: { retorno: { status: 'OK', status_processamento: '3' } }.to_json)
  end

  test 'cancels the order in Tiny, unlinks it from Honey and leaves it ready to be resent' do
    order = sent_order
    stub = stub_status_ok

    post cancel_in_tiny_b2b_order_path(order)

    assert_requested stub
    order.reload
    assert_nil order.tiny_reference_id
    assert_nil order.tiny_reference_number
    assert order.aberto?
    assert order.resendable?
    assert_redirected_to b2b_orders_path
    follow_redirect!
    assert_select '.flash-messages-container .alert-success', text: /nº 1900.*cancelado no Tiny/
  end

  test 'the cancellation is recorded in the audit log with the old Tiny reference' do
    order = sent_order
    stub_status_ok

    assert_difference 'Log.count', 1 do
      post cancel_in_tiny_b2b_order_path(order)
    end

    log = Log.last
    assert_equal 'b2b_order', log.resource_type
    assert_equal 'cancel_in_tiny', log.action_type
    assert_equal @admin, log.user
    assert_equal '555', log.details_parsed['tiny_reference_id']
    assert_equal '1900', log.details_parsed['tiny_reference_number']
  end

  test 'after the cancellation the order can be sent again as a brand new Tiny order' do
    order = sent_order
    stub_status_ok
    post cancel_in_tiny_b2b_order_path(order)
    stub_request(:post, PEDIDO_URL).to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '777', numero: '1950' } } } }.to_json)

    post transmit_b2b_order_path(order)

    order.reload
    assert_equal '777', order.tiny_reference_id
    assert_equal '1950', order.tiny_reference_number
  end

  test 'when Tiny refuses, nothing changes in Honey and the real Tiny message is shown' do
    order = sent_order
    stub_request(:post, STATUS_URL).to_return(body: { retorno: { status: 'Erro', codigo_erro: '20', erros: [{ erro: 'Pedido já faturado não pode ser cancelado' }] } }.to_json)

    assert_no_difference 'Log.count' do
      post cancel_in_tiny_b2b_order_path(order)
    end

    order.reload
    assert_equal '555', order.tiny_reference_id
    assert order.aprovado?
    follow_redirect!
    assert_select '.flash-messages-container .alert-danger', text: /Pedido já faturado não pode ser cancelado/
  end

  test 'a network failure is reported and nothing changes' do
    order = sent_order
    stub_request(:post, STATUS_URL).to_timeout

    post cancel_in_tiny_b2b_order_path(order)

    assert_equal '555', order.reload.tiny_reference_id
    follow_redirect!
    assert_select '.flash-messages-container .alert-danger'
  end

  test 'an order that was never sent to Tiny has nothing to cancel and Tiny is not called' do
    order = build_order(status: :dados_incompletos)
    stub = stub_request(:post, STATUS_URL)

    post cancel_in_tiny_b2b_order_path(order)

    assert_not_requested stub
    follow_redirect!
    assert_select '.flash-messages-container .alert-danger', text: /não foi enviado ao Tiny/
  end

  test 'stock transfers cannot be cancelled from the wholesale screen' do
    transfer = build_order(kind: :stock_transfer, tiny_reference_id: '555', tiny_reference_number: '9')
    stub = stub_request(:post, STATUS_URL)

    post cancel_in_tiny_b2b_order_path(transfer)

    assert_response :not_found
    assert_not_requested stub
    assert_equal '555', transfer.reload.tiny_reference_id
  end

  test 'the button shows on the list and on the edit page only for orders already in Tiny' do
    sent = sent_order
    pending = build_order(status: :dados_incompletos)

    get b2b_orders_path
    assert_select "form[action='#{cancel_in_tiny_b2b_order_path(sent)}']", count: 1
    assert_select "form[action='#{cancel_in_tiny_b2b_order_path(pending)}']", count: 0

    get edit_b2b_order_path(sent)
    assert_select "form[action='#{cancel_in_tiny_b2b_order_path(sent)}']", count: 1
    get edit_b2b_order_path(pending)
    assert_select "form[action='#{cancel_in_tiny_b2b_order_path(pending)}']", count: 0
  end

  test 'the button asks for confirmation explaining what will happen' do
    get b2b_orders_path
    sent = sent_order
    get b2b_orders_path

    assert_select "form[action='#{cancel_in_tiny_b2b_order_path(sent)}'][data-turbo-confirm*='Cancelado']"
  end

  test 'it requires the b2b_orders permission' do
    order = sent_order
    profile = Profile.create!(name: 'Sem Acesso Cancel')
    user = User.create!(name: 'Sem Acesso', email: 'sem_acesso_cancel@example.com', password: 'password123')
    user.profiles << profile
    stub = stub_request(:post, STATUS_URL)
    sign_in user

    post cancel_in_tiny_b2b_order_path(order)

    assert_redirected_to root_path
    assert_not_requested stub
    assert_equal '555', order.reload.tiny_reference_id
  end
  OBTER_URL = 'https://api.tiny.com.br/api2/pedido.obter.php'.freeze

  def stub_status_refused
    stub_request(:post, STATUS_URL).to_return(body: { retorno: { status: 'Erro', erros: [{ erro: 'Pedido não localizado' }] } }.to_json)
  end

  test 'when the order no longer exists in Tiny, cancelling just removes the link' do
    order = sent_order
    stub_status_refused
    stub_request(:get, OBTER_URL).with(query: hash_including('id' => '555'))
      .to_return(body: { retorno: { status: 'Erro', codigo_erro: '20', erros: [{ erro: 'A consulta não retornou registros' }] } }.to_json)

    post cancel_in_tiny_b2b_order_path(order)

    order.reload
    assert_nil order.tiny_reference_id
    assert order.aberto?
    assert Log.last.details_parsed['missing_in_tiny']
    follow_redirect!
    assert_select '.flash-messages-container .alert-success', text: /não existe mais no Tiny.*vínculo foi removido/
  end

  test 'when the order still exists in Tiny and the cancellation is refused, the link is kept' do
    order = sent_order
    stub_status_refused
    stub_request(:get, OBTER_URL).with(query: hash_including('id' => '555'))
      .to_return(body: { retorno: { status: 'OK', pedido: { id: '555', situacao: 'Faturado' } } }.to_json)

    post cancel_in_tiny_b2b_order_path(order)

    assert_equal '555', order.reload.tiny_reference_id
  end
end
