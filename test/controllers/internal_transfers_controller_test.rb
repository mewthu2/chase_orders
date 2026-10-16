require 'test_helper'
require 'webmock/minitest'

class InternalTransfersControllerTest < ActionDispatch::IntegrationTest
  GRAPHQL_URL = 'https://chasebrasil.myshopify.com/admin/api/2025-01/graphql.json'.freeze
  LEVELS_URL = %r{\Ahttps://chasebrasil\.myshopify\.com/admin/api/2025-01/inventory_levels\.json}

  def setup
    ENV['CHASE_ORDERS_TOKEN'] = 'fake-shopify-token'
    @admin = User.create!(name: 'Admin', email: 'admin_it@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @lagoa = Location.create!(slug: 'lagoa_seca', name: 'Lagoa Seca', shopify_location_id: '111')
    @bh = Location.create!(slug: 'bh_shopping', name: 'BH Shopping', shopify_location_id: '222')
    @a = Product.create!(sku: 'SKU-A', shopify_product_name: 'Camiseta', shopify_inventory_item_id: '9001', image_url: 'https://cdn.example.com/a.png')
    @b = Product.create!(sku: 'SKU-B', shopify_product_name: 'Calça', shopify_inventory_item_id: '9002', image_url: 'https://cdn.example.com/b.png')
    sign_in @admin
  end

  def manager_profile
    @manager_profile ||= Profile.create!(name: 'Gerente IT').tap { |p| p.update!(screen_keys: ['internal_transfers']) }
  end

  def gerente_lagoa
    user = User.create!(name: 'Gerente Lagoa', email: 'gerente_lagoa_it@example.com', password: 'password123', allowed_locations: ['lagoa_seca'])
    user.profiles << manager_profile
    user
  end

  def build_transfer(items: [[@bh, @a, 2]], destination: @lagoa, requester: @admin)
    transfer = InternalTransfer.new(destination_location: destination, requested_by: requester, approval_status: :aprovada)
    items.group_by { |origin, _, _| origin }.each do |origin, group|
      shipment = transfer.shipments.build(origin_location: origin)
      group.each { |_, product, qty| shipment.items.build(product: product, quantity: qty) }
    end
    transfer.save!
    transfer
  end

  test 'user without the internal_transfers permission is redirected' do
    profile = Profile.create!(name: 'Sem Transferencia')
    user = User.create!(name: 'Sem Acesso', email: 'sem_it@example.com', password: 'password123')
    user.profiles << profile
    sign_in user

    get internal_transfers_path
    assert_redirected_to root_path
  end

  test 'a manager with a single store sees it fixed as "Minha loja é" and cannot choose another' do
    sign_in gerente_lagoa

    get new_internal_transfer_path

    assert_response :success
    assert_select 'select[name="internal_transfer[destination_location_id]"]', count: 0
    assert_includes response.body, 'Minha loja é'
    assert_includes response.body, 'Lagoa Seca'
    assert_select "input[name='internal_transfer[destination_location_id]'][value='#{@lagoa.id}']"
  end

  test 'an admin chooses the destination store from a select' do
    get new_internal_transfer_path

    assert_select 'select[name="internal_transfer[destination_location_id]"] option', minimum: 2
  end

  test 'the destination store cannot be picked as an origin' do
    get new_internal_transfer_path(destination_location_id: @lagoa.id)

    assert_select "input[name='location_ids[]'][value='#{@lagoa.id}']", count: 0
    assert_select "input[name='location_ids[]'][value='#{@bh.id}']"
  end

  test 'create groups items from the same origin into a single shipment' do
    assert_difference 'InternalTransfer.count', 1 do
      assert_difference 'InternalTransferShipment.count', 1 do
        post internal_transfers_path, params: { internal_transfer: {
          destination_location_id: @lagoa.id,
          items: { '0' => { product_id: @a.id, location_id: @bh.id, quantity: '2' },
                   '1' => { product_id: @b.id, location_id: @bh.id, quantity: '1' } }
        } }
      end
    end

    transfer = InternalTransfer.last
    assert_equal @admin, transfer.requested_by
    assert_equal 1, transfer.shipments.count
    assert_equal 2, transfer.shipments.first.items.count
    assert transfer.shipments.first.aberto?
    assert transfer.approval_pendente?
    assert_redirected_to internal_transfer_path(transfer)
  end

  test 'create opens one shipment per distinct origin store' do
    rj = Location.create!(slug: 'rj', name: 'RJ', shopify_location_id: '333')

    post internal_transfers_path, params: { internal_transfer: {
      destination_location_id: @lagoa.id,
      items: { '0' => { product_id: @a.id, location_id: @bh.id, quantity: '2' },
               '1' => { product_id: @b.id, location_id: rj.id, quantity: '1' } }
    } }

    transfer = InternalTransfer.last
    assert_equal 2, transfer.shipments.count
    assert_equal [@bh, rj].map(&:id).sort, transfer.shipments.map(&:origin_location_id).sort
  end

  test 'a manager can only request transfers to her own store' do
    outra = Location.create!(slug: 'rj', name: 'RJ', shopify_location_id: '333')
    sign_in gerente_lagoa

    post internal_transfers_path, params: { internal_transfer: {
      destination_location_id: outra.id,
      items: { '0' => { product_id: @a.id, location_id: @bh.id, quantity: '1' } }
    } }

    assert_response :unprocessable_entity
    assert_no_difference('InternalTransfer.count') { }
  end

  test 'create without items re-renders with the error' do
    assert_no_difference 'InternalTransfer.count' do
      post internal_transfers_path, params: { internal_transfer: { destination_location_id: @lagoa.id, items: {} } }
    end

    assert_response :unprocessable_entity
    assert_select '.form-error-box', text: /pelo menos um item/
  end

  test 'a product not linked to Shopify is refused with its SKU' do
    unlinked = Product.create!(sku: 'SEM-ID', shopify_product_name: 'Sem vínculo')

    assert_no_difference 'InternalTransfer.count' do
      post internal_transfers_path, params: { internal_transfer: {
        destination_location_id: @lagoa.id, items: { '0' => { product_id: unlinked.id, location_id: @bh.id, quantity: '1' } }
      } }
    end

    assert_select '.form-error-box', text: /SEM-ID/
  end

  test 'index lists transfers and highlights the ones needing action from the current store' do
    rj = Location.create!(slug: 'rj', name: 'RJ', shopify_location_id: '333')
    sp = Location.create!(slug: 'eldorado_sp', name: 'Eldorado SP', shopify_location_id: '444')
    visible = build_transfer # destino Lagoa Seca, origem BH
    visible.shipments.first.update!(status: :enviado) # aguardando a gerente de Lagoa Seca receber
    build_transfer(items: [[rj, @b, 1]], destination: sp) # outra transferência, sem relação com Lagoa Seca

    sign_in gerente_lagoa
    get internal_transfers_path

    assert_response :success
    assert_select 'tbody tr', count: 1
    assert_select '.action-needed-badge', minimum: 1
  end

  test 'the index and show pages do not query products or locations line by line' do
    rj = Location.create!(slug: 'rj', name: 'RJ', shopify_location_id: '333')
    3.times { build_transfer(items: [[@bh, @a, 1], [rj, @b, 1]], destination: @lagoa) }

    products = 0
    counter = ->(*, payload) { products += 1 if payload[:sql].match?(/FROM `products`/) }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') { get internal_transfers_path }
    assert_operator products, :<=, 1

    transfer = build_transfer(items: [[@bh, @a, 1], [rj, @b, 1]], destination: @lagoa)
    products = 0
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') { get internal_transfer_path(transfer) }
    assert_operator products, :<=, 1
  end

  test 'show renders the timeline with events' do
    transfer = build_transfer
    InternalTransferEvent.create!(internal_transfer: transfer, user: @admin, action: 'created', message: 'Transferência criada.')

    get internal_transfer_path(transfer)

    assert_select '.internal-transfer-timeline', text: /Transferência criada/
  end

  test 'a fully open transfer can be edited and deleted; once a shipment moves, it cannot' do
    transfer = build_transfer

    get edit_internal_transfer_path(transfer)
    assert_response :success

    transfer.shipments.first.update!(status: :reservado)
    get edit_internal_transfer_path(transfer)
    assert_redirected_to internal_transfer_path(transfer)

    assert_no_difference 'InternalTransfer.count' do
      delete internal_transfer_path(transfer)
    end
  end

  test 'deleting a fully open transfer removes it' do
    transfer = build_transfer

    assert_difference 'InternalTransfer.count', -1 do
      delete internal_transfer_path(transfer)
    end
    assert_redirected_to internal_transfers_path
  end

  test 'Correios Log is not offered as a destination or an origin store' do
    log = Location.create!(slug: 'log+', name: 'Correios Log +', shopify_location_id: '999')

    get new_internal_transfer_path
    assert_select "input[name='location_ids[]'][value='#{log.id}']", count: 0
    refute_includes response.body, 'Correios Log'

    sign_in gerente_lagoa
    get new_internal_transfer_path
    refute_includes response.body, 'Correios Log'
  end

  test 'Correios Log cannot be picked as the destination, even by an admin sending the id directly' do
    log = Location.create!(slug: 'log+', name: 'Correios Log +', shopify_location_id: '999')

    assert_no_difference 'InternalTransfer.count' do
      post internal_transfers_path, params: { internal_transfer: {
        destination_location_id: log.id, items: { '0' => { product_id: @a.id, location_id: @bh.id, quantity: '1' } }
      } }
    end
    assert_response :unprocessable_entity
  end

  test 'an item aimed at Correios Log as origin is silently dropped, even if sent directly' do
    log = Location.create!(slug: 'log+', name: 'Correios Log +', shopify_location_id: '999')

    post internal_transfers_path, params: { internal_transfer: {
      destination_location_id: @lagoa.id,
      items: { '0' => { product_id: @a.id, location_id: log.id, quantity: '1' },
               '1' => { product_id: @b.id, location_id: @bh.id, quantity: '1' } }
    } }

    transfer = InternalTransfer.last
    assert_equal [@bh.id], transfer.shipments.map(&:origin_location_id)
  end

  test 'search_product only returns products linked to Shopify, with photo' do
    Product.create!(sku: 'SEM-ID', shopify_product_name: 'Sem vínculo')

    get search_product_internal_transfers_path, params: { query: 'camiseta' }
    json = JSON.parse(response.body)

    assert_equal ['SKU-A'], json['products'].map { |p| p['sku'] }
    assert_equal 'https://cdn.example.com/a.png', json['products'].first['image_url']
  end

  test 'live_stock returns the real Shopify availability for the selected origin stores' do
    stub_request(:get, LEVELS_URL).to_return do |request|
      query = Addressable::URI.parse(request.uri).query_values
      rows = query['inventory_item_ids'].split(',').map { |id| { inventory_item_id: id.to_i, location_id: query['location_ids'].to_i, available: 7 } }
      { body: { inventory_levels: rows }.to_json, headers: { 'Content-Type' => 'application/json' } }
    end

    get live_stock_internal_transfers_path, params: { product_ids: [@a.id], location_ids: [@bh.id] }
    json = JSON.parse(response.body)

    assert_equal 7, json['stock'][@a.id.to_s][@bh.id.to_s]
  end

  def pending_transfer
    transfer = build_transfer
    transfer.update!(approval_status: :pendente)
    transfer
  end

  def aprovador(email: 'aprovador_it@example.com')
    user = User.create!(name: 'Aprovador', email: email, password: 'password123', allowed_locations: ['eldorado_sp'])
    user.profiles << Profile.create!(name: "Sem Transferencia #{email}")
    InternalTransferApprover.create!(user: user)
    user
  end

  test 'only an admin can open the approver configuration' do
    get edit_internal_transfer_config_path
    assert_response :success

    sign_in gerente_lagoa
    get edit_internal_transfer_config_path
    assert_redirected_to root_path
  end

  test 'an admin sets several approvers and can remove one later' do
    ana = User.create!(name: 'Ana', email: 'ana_it@example.com', password: 'password123')
    bia = User.create!(name: 'Bia', email: 'bia_it@example.com', password: 'password123')

    patch internal_transfer_config_path, params: { approver_ids: ['', ana.id, bia.id] }
    assert_redirected_to internal_transfers_path
    assert_equal [ana.id, bia.id].sort, InternalTransferApprover.user_ids.sort

    patch internal_transfer_config_path, params: { approver_ids: ['', bia.id] }
    assert_equal [bia.id], InternalTransferApprover.user_ids

    get edit_internal_transfer_config_path
    assert_select "input[type=checkbox][name='approver_ids[]'][value='#{bia.id}'][checked]"
    assert_select "input[type=checkbox][name='approver_ids[]'][value='#{ana.id}']:not([checked])"
  end

  test 'any of several approvers can approve' do
    transfer = pending_transfer
    aprovador
    segundo = aprovador(email: 'segundo_aprovador_it@example.com')
    sign_in segundo

    get internal_transfer_path(transfer)
    assert_includes response.body, 'Aprovador, Aprovador ou um admin'

    post approve_internal_transfer_path(transfer)
    assert transfer.reload.approval_aprovada?
    assert_equal segundo, transfer.reviewed_by
  end

  test 'the approver sees pending transfers and approves them even without the screen in the profile' do
    transfer = pending_transfer
    sign_in aprovador

    get internal_transfers_path
    assert_response :success
    assert_includes response.body, "##{transfer.id}"
    assert_includes response.body, 'Aguardando sua ação'

    get internal_transfer_path(transfer)
    assert_select 'button', text: /Aprovar/

    post approve_internal_transfer_path(transfer)
    assert_redirected_to internal_transfer_path(transfer)
    assert transfer.reload.approval_aprovada?

    get new_internal_transfer_path
    assert_redirected_to root_path
  end

  test 'the approver rejects with a reason and every shipment is cancelled' do
    transfer = pending_transfer
    sign_in aprovador

    post reject_internal_transfer_path(transfer), params: { rejection_reason: 'Estoque baixo' }

    transfer.reload
    assert transfer.approval_reprovada?
    assert_equal 'Estoque baixo', transfer.rejection_reason
    assert transfer.shipments.all?(&:cancelado?)
  end

  test 'an admin approves even without being a configured approver' do
    transfer = pending_transfer
    aprovador

    get internal_transfers_path
    assert_includes response.body, 'Aguardando sua ação'
    get internal_transfer_path(transfer)
    assert_select 'button', text: /Aprovar/

    post approve_internal_transfer_path(transfer)

    assert_redirected_to internal_transfer_path(transfer)
    assert transfer.reload.approval_aprovada?
    assert_equal @admin, transfer.reviewed_by
  end

  test 'a user who is neither approver nor admin cannot approve' do
    transfer = pending_transfer
    aprovador
    sign_in gerente_lagoa

    post approve_internal_transfer_path(transfer)

    assert_redirected_to internal_transfer_path(transfer)
    assert transfer.reload.approval_pendente?
  end

  test 'with no approver configured the transfers are not stuck: admins approve' do
    pending_transfer
    get internal_transfers_path

    assert_no_match(/Nenhum aprovador configurado/, response.body)
  end

  test 'a pending transfer shows no reserve button' do
    transfer = pending_transfer
    get internal_transfer_path(transfer)

    assert_includes response.body, 'Aguardando aprovação'
    assert_select 'button', text: /Reservar/, count: 0
  end

  test 'editing an approved transfer sends it back to approval' do
    transfer = build_transfer

    patch internal_transfer_path(transfer), params: { internal_transfer: {
      destination_location_id: @lagoa.id, items: { '0' => { product_id: @a.id, location_id: @bh.id, quantity: '5' } }
    } }

    assert_redirected_to internal_transfer_path(transfer)
    transfer.reload
    assert transfer.approval_pendente?
    assert_nil transfer.reviewed_by
    refute transfer.shipments.first.reservable?
  end

  # ---- Lista: busca, filtros, abas de status e paginação ----
  test 'the list searches by number, SKU, product name, requester and tracking code' do
    camiseta = build_transfer(items: [[@bh, @a, 1]])
    calca = build_transfer(items: [[@bh, @b, 1]])
    calca.shipments.first.update!(tracking_code: 'QB123456789BR')

    { 'SKU-A' => camiseta, 'Calça' => calca, 'QB1234' => calca, "##{camiseta.id}" => camiseta }.each do |q, expected|
      get internal_transfers_path(q:)
      assert_select 'tbody tr', count: 1, message: "busca #{q}"
      assert_select 'tbody td.text-main', text: "##{expected.id}"
    end

    get internal_transfers_path(q: 'Admin')
    assert_select 'tbody tr', count: 2
  end

  test 'the list filters by destination, origin and period' do
    to_lagoa = build_transfer(items: [[@bh, @a, 1]], destination: @lagoa)
    to_bh = build_transfer(items: [[@lagoa, @a, 1]], destination: @bh)
    to_bh.update_columns(created_at: 10.days.ago)

    get internal_transfers_path(destination_id: @bh.id)
    assert_select 'tbody td.text-main', text: "##{to_bh.id}"
    assert_select 'tbody tr', count: 1

    get internal_transfers_path(origin_id: @bh.id)
    assert_select 'tbody td.text-main', text: "##{to_lagoa.id}"
    assert_select 'tbody tr', count: 1

    get internal_transfers_path(from: 2.days.ago.to_date.iso8601, to: Date.current.iso8601)
    assert_select 'tbody td.text-main', text: "##{to_lagoa.id}"
    assert_select 'tbody tr', count: 1

    get internal_transfers_path(from: 'lixo')
    assert_select 'tbody tr', count: 2
  end

  test 'status tabs count and filter by the overall status' do
    pending = build_transfer
    pending.update_columns(approval_status: InternalTransfer.approval_statuses[:pendente])
    open = build_transfer
    sent = build_transfer
    sent.shipments.first.update_columns(status: InternalTransferShipment.statuses[:enviado])
    done = build_transfer
    done.shipments.first.update_columns(status: InternalTransferShipment.statuses[:recebido])
    cancelled = build_transfer
    cancelled.shipments.first.update_columns(status: InternalTransferShipment.statuses[:cancelado])

    expected = { 'aguardando_aprovacao' => pending, 'aberto' => open, 'em_andamento' => sent, 'concluida' => done, 'cancelada' => cancelled }
    expected.each do |status, transfer|
      assert_equal status, transfer.reload.overall_status
      assert_equal [transfer.id], InternalTransfer.with_overall_status(status).ids, status
    end

    get internal_transfers_path(status: 'em_andamento')
    assert_select 'tbody tr', count: 1
    assert_select 'tbody td.text-main', text: "##{sent.id}"
    assert_select '.status-tab--active', text: /Em andamento\s*1/
    assert_select '.status-tab', text: /Todas\s*5/
  end

  test 'filters are kept in the status tabs and pagination respects the page size' do
    21.times { build_transfer }

    get internal_transfers_path(destination_id: @lagoa.id)
    assert_select 'tbody tr', count: 20
    assert_select "a.status-tab[href*='destination_id=#{@lagoa.id}'][href*='status=aberto']"
    assert_select '.pagination'

    get internal_transfers_path(per_page: 50)
    assert_select 'tbody tr', count: 21
  end

  test 'the "waiting on me" toggle lists only transfers that need the user' do
    receivable = build_transfer(items: [[@bh, @a, 1]], destination: @lagoa)
    receivable.shipments.first.update_columns(status: InternalTransferShipment.statuses[:enviado])
    build_transfer(items: [[@lagoa, @a, 1]], destination: @bh).shipments.first
                  .update_columns(status: InternalTransferShipment.statuses[:enviado])
    sign_in gerente_lagoa

    get internal_transfers_path(mine: '1')

    assert_select 'tbody tr', count: 1
    assert_select 'tbody td.text-main', text: "##{receivable.id}"
  end
end
