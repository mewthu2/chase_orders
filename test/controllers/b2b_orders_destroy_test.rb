require 'test_helper'
require 'webmock/minitest'

class B2bOrdersDestroyTest < ActionDispatch::IntegrationTest
  STATUS_URL = 'https://api.tiny.com.br/api2/pedido.alterar.situacao.php'.freeze

  def setup
    ENV['TOKEN_TINY2_PRODUCTION'] = 'fake-token-tiny2'
    @admin = User.create!(name: 'Admin Excluir', email: 'admin_destroy@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @client = Client.create!(responsible_name: 'Cliente Excluir', registration: '25.405.327/0001-74')
    @location = TransferLocation.create!(
      name: 'CD Excluir', registration: '25.405.327/0001-74', street: 'Rua A', number: '10',
      neighbourhood: 'Bairro', city: 'BH', state: 'MG', zip: '30000-000'
    )
    sign_in @admin
    # Por padrão o pedido existe no Tiny (consultado quando o cancelamento é recusado).
    stub_request(:get, 'https://api.tiny.com.br/api2/pedido.obter.php').with(query: hash_including('formato' => 'json'))
      .to_return(body: { retorno: { status: 'OK', pedido: { id: '555', situacao: 'Faturado' } } }.to_json)
  end

  def build_order(kind: :sale, **attrs)
    target = kind == :sale ? { client: @client } : { transfer_location: @location, price_list: :transfer }
    order = B2bOrder.new({ kind: kind, user: @admin, status: :dados_incompletos }.merge(target).merge(attrs))
    order.b2b_order_items.build(sku: 'SKU1', name: 'Produto', quantity: 2, price: 10)
    order.b2b_order_items.build(sku: 'SKU2', name: 'Produto 2', quantity: 1, price: 5)
    order.save!
    order
  end

  def sent_order(**attrs)
    build_order(status: :aprovado, tiny_reference_id: '555', tiny_reference_number: '1900', **attrs)
  end

  def company
    @company ||= Company.create!(
      legal_name: 'Empresa Nota', cnpj: '11222333000181', tax_regime: 1, street: 'Rua A', number: '1',
      neighbourhood: 'Centro', city: 'BH', city_ibge_code: '3106200', state: 'MG', zip: '30000000'
    )
  end

  def note_for(order, status)
    FiscalNote.create!(company: company, b2b_order: order, number: FiscalNote.count + 1, series: 1, status: status)
  end

  test 'an order that is not in Tiny can be deleted, with its items' do
    order = build_order

    assert_difference 'B2bOrder.count', -1 do
      assert_difference 'B2bOrderItem.count', -2 do
        delete b2b_order_path(order)
      end
    end

    assert_redirected_to b2b_orders_path
    follow_redirect!
    assert_select '.flash-messages-container .alert-success', text: /Pedido ##{order.id} excluído/
  end

  test 'deleting an order already in Tiny cancels it there first and then removes it from Honey' do
    order = sent_order
    stub = stub_request(:post, STATUS_URL).with(body: hash_including('id' => '555', 'situacao' => 'cancelado'))
                                          .to_return(body: { retorno: { status: 'OK' } }.to_json)

    assert_difference 'B2bOrder.count', -1 do
      delete b2b_order_path(order)
    end

    assert_requested stub
    assert_redirected_to b2b_orders_path
    follow_redirect!
    assert_select '.flash-messages-container .alert-success', text: /excluído.*cancelado no Tiny, nº 1900/
    assert_equal '555', Log.last.details_parsed['tiny_reference_id']
  end

  test 'when Tiny does not cancel the order it is kept in Honey' do
    order = sent_order
    stub_request(:post, STATUS_URL).to_return(body: { retorno: { status: 'Erro', erros: [{ erro: 'Pedido faturado' }] } }.to_json)

    assert_no_difference 'B2bOrder.count' do
      delete b2b_order_path(order)
    end

    follow_redirect!
    assert_select '.flash-messages-container .alert-danger', text: /nº 1900.*não foi excluído/m
  end

  test 'a sent order with an active fiscal note is not deleted nor cancelled in Tiny' do
    order = sent_order
    note_for(order, :autorizada)

    assert_no_difference 'B2bOrder.count' do
      delete b2b_order_path(order)
    end
    assert_not_requested :post, STATUS_URL
  end

  test 'an order with an active fiscal note cannot be deleted, but one whose note failed can' do
    with_note = build_order
    note_for(with_note, :assinada)
    with_failed_note = build_order
    note_for(with_failed_note, :erro)

    assert_no_difference 'B2bOrder.count' do
      delete b2b_order_path(with_note)
    end
    follow_redirect!
    assert_select '.flash-messages-container .alert-danger', text: /nota fiscal/

    assert_difference 'B2bOrder.count', -1 do
      delete b2b_order_path(with_failed_note)
    end
  end

  test 'the deletion is recorded in the audit log' do
    order = build_order

    assert_difference 'Log.count', 1 do
      delete b2b_order_path(order)
    end

    log = Log.last
    assert_equal 'b2b_order', log.resource_type
    assert_equal 'delete', log.action_type
    assert_equal @admin, log.user
    assert_equal 25, log.details_parsed['total'].to_i
    assert_equal 2, log.details_parsed['items']
  end

  test 'stock transfers follow the same rule through their own screen, and not through the wholesale one' do
    transfer = build_order(kind: :stock_transfer)

    delete b2b_order_path(transfer)
    assert_response :not_found
    assert B2bOrder.exists?(transfer.id)

    sign_in @admin
    assert_difference 'B2bOrder.count', -1 do
      delete stock_transfer_path(transfer)
    end
    assert_redirected_to stock_transfers_path

    sent = build_order(kind: :stock_transfer, tiny_reference_id: '9', tiny_reference_number: '9')
    assert_no_difference 'B2bOrder.count' do
      delete stock_transfer_path(sent)
    end
  end

  test 'the delete button shows on the list and on the edit page for orders without an active fiscal note' do
    free = build_order
    in_tiny = sent_order
    with_note = build_order
    note_for(with_note, :autorizada)

    get b2b_orders_path
    assert_select "form[action='#{b2b_order_path(free)}'] input[name=_method][value=delete]", count: 1
    assert_select "form[action='#{b2b_order_path(in_tiny)}'][data-turbo-confirm*='CANCELADO no Tiny (nº 1900)'] input[name=_method][value=delete]", count: 1
    assert_select "form[action='#{b2b_order_path(with_note)}'] input[name=_method][value=delete]", count: 0

    get edit_b2b_order_path(free)
    assert_select "form[action='#{b2b_order_path(free)}'] input[name=_method][value=delete]", count: 1
    get edit_b2b_order_path(in_tiny)
    assert_select "form[action='#{b2b_order_path(in_tiny)}'] input[name=_method][value=delete]", count: 1
  end

  test 'the delete button also shows on the stock transfers list' do
    transfer = build_order(kind: :stock_transfer)

    get stock_transfers_path

    assert_select "form[action='#{stock_transfer_path(transfer)}'] input[name=_method][value=delete]", count: 1
  end

  test 'the button asks for confirmation' do
    order = build_order

    get b2b_orders_path

    assert_select "form[action='#{b2b_order_path(order)}'][data-turbo-confirm*='não foi enviado ao Tiny']"
  end

  test 'it requires the b2b_orders permission' do
    order = build_order
    profile = Profile.create!(name: 'Sem Excluir')
    user = User.create!(name: 'Sem Excluir', email: 'sem_destroy@example.com', password: 'password123')
    user.profiles << profile
    sign_in user

    assert_no_difference 'B2bOrder.count' do
      delete b2b_order_path(order)
    end
    assert_redirected_to root_path
  end

  test 'the list does not query fiscal notes once per order' do
    4.times { build_order }
    count = 0
    counter = ->(*, payload) { count += 1 if payload[:sql].match?(/FROM `fiscal_notes`/) }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') { get b2b_orders_path }

    assert_operator count, :<=, 1
  end

  test 'deletable? is a model rule: no active fiscal note, and a sent stock transfer (a nota in Tiny) is never deletable' do
    order = build_order

    assert order.deletable?
    order.tiny_reference_id = '1'
    assert order.deletable?
    refute build_order(kind: :stock_transfer, tiny_reference_id: '9').deletable?
    order.tiny_reference_id = nil
    note_for(order, :assinada)
    refute order.reload.deletable?
  end
  test 'deleting an order that no longer exists in Tiny removes it from Honey' do
    order = sent_order
    stub_request(:post, STATUS_URL).to_return(body: { retorno: { status: 'Erro', erros: [{ erro: 'Pedido não encontrado' }] } }.to_json)
    stub_request(:get, 'https://api.tiny.com.br/api2/pedido.obter.php').with(query: hash_including('id' => '555'))
      .to_return(body: { retorno: { status: 'Erro', erros: [{ erro: 'Registro não encontrado' }] } }.to_json)

    assert_difference 'B2bOrder.count', -1 do
      delete b2b_order_path(order)
    end
    follow_redirect!
    assert_select '.flash-messages-container .alert-success', text: /já não existia no Tiny/
  end
end
