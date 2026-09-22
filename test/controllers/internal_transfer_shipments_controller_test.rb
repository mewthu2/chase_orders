require 'test_helper'
require 'webmock/minitest'

class InternalTransferShipmentsControllerTest < ActionDispatch::IntegrationTest
  GRAPHQL_URL = 'https://chasebrasil.myshopify.com/admin/api/2025-01/graphql.json'.freeze
  LEVELS_URL = %r{\Ahttps://chasebrasil\.myshopify\.com/admin/api/2025-01/inventory_levels\.json}

  def setup
    ENV['CHASE_ORDERS_TOKEN'] = 'fake-shopify-token'
    @admin = User.create!(name: 'Admin', email: 'admin_shp@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @requester = User.create!(name: 'Solicitante', email: 'solicitante_shp_ctrl@example.com', password: 'password123')
    @requester.profiles << manager_profile
    @lagoa = Location.create!(slug: 'lagoa_seca', name: 'Lagoa Seca', shopify_location_id: '111')
    @bh = Location.create!(slug: 'bh_shopping', name: 'BH Shopping', shopify_location_id: '222')
    @product = Product.create!(sku: 'SKU-A', shopify_product_name: 'Camiseta', shopify_inventory_item_id: '9001')
    sign_in @admin
  end

  def manager_profile
    @manager_profile ||= Profile.create!(name: 'Gerente IT Shp').tap { |p| p.update!(screen_keys: ['internal_transfers']) }
  end

  def gerente(slug, name: 'Gerente')
    user = User.create!(name: name, email: "#{slug}_shp@example.com", password: 'password123', allowed_locations: [slug])
    user.profiles << manager_profile
    user
  end

  def build_transfer(quantity: 2, status: :aberto)
    transfer = InternalTransfer.new(destination_location: @lagoa, requested_by: @requester)
    shipment = transfer.shipments.build(origin_location: @bh)
    shipment.items.build(product: @product, quantity: quantity)
    transfer.save!
    shipment.update!(status: status)
    shipment.items.each { |item| item.update!(status: :reserved, available_before: 10) } unless status == :aberto
    shipment
  end

  def stub_levels(available)
    stub_request(:get, LEVELS_URL).to_return do |request|
      query = Addressable::URI.parse(request.uri).query_values
      rows = query['inventory_item_ids'].split(',').filter_map do |id|
        { inventory_item_id: id.to_i, location_id: query['location_ids'].to_i, available: available } if available
      end
      { body: { inventory_levels: rows }.to_json, headers: { 'Content-Type' => 'application/json' } }
    end
  end

  def stub_adjust
    stub_request(:post, GRAPHQL_URL).to_return(body: { data: { inventoryAdjustQuantities: { userErrors: [], inventoryAdjustmentGroup: { id: 'gid://1' } } } }.to_json)
  end

  test 'the manager of the origin store can reserve, the destination manager cannot' do
    shipment = build_transfer
    stub_levels(10)
    stub_adjust

    sign_in gerente('lagoa_seca')
    post reserve_internal_transfer_shipment_path(shipment.internal_transfer, shipment)
    assert_redirected_to internal_transfer_path(shipment.internal_transfer)
    assert shipment.reload.aberto?, 'quem não gerencia a origem não pode reservar'

    sign_in gerente('bh_shopping')
    post reserve_internal_transfer_shipment_path(shipment.internal_transfer, shipment)
    assert shipment.reload.reservado?
  end

  test 'reserving shows the result and a partial failure is reported' do
    shipment = build_transfer(quantity: 20)
    stub_levels(5)

    post reserve_internal_transfer_shipment_path(shipment.internal_transfer, shipment)

    follow_redirect!
    assert_select '.flash-messages-container .alert-danger', text: /falha/i
    assert shipment.reload.aberto?
  end

  test 'shipping requires reserved status, accepts a tracking code and only the origin manager (or admin) can do it' do
    shipment = build_transfer(status: :reservado)
    manager = gerente('bh_shopping')

    sign_in manager
    post ship_internal_transfer_shipment_path(shipment.internal_transfer, shipment), params: { tracking_code: 'BR123456789BR' }

    shipment.reload
    assert shipment.enviado?
    assert_equal 'BR123456789BR', shipment.tracking_code
    assert_equal manager, shipment.sent_by
  end

  test 'shipping a shipment that is not reserved is refused' do
    shipment = build_transfer

    post ship_internal_transfer_shipment_path(shipment.internal_transfer, shipment), params: { tracking_code: 'X' }

    refute shipment.reload.enviado?
  end

  test 'a manager of another store cannot ship it' do
    shipment = build_transfer(status: :reservado)
    other = gerente('rj')

    sign_in other
    post ship_internal_transfer_shipment_path(shipment.internal_transfer, shipment), params: { tracking_code: 'X' }

    refute shipment.reload.enviado?
  end

  test 'the destination manager can receive it and update the tracking code afterwards' do
    shipment = build_transfer(status: :enviado)
    shipment.update!(tracking_code: 'OLD')
    stub_adjust

    sign_in gerente('lagoa_seca')
    post receive_internal_transfer_shipment_path(shipment.internal_transfer, shipment)

    assert shipment.reload.recebido?
    assert_not_nil shipment.received_at
  end

  test 'the origin manager cannot mark it as received' do
    shipment = build_transfer(status: :enviado)

    sign_in gerente('bh_shopping')
    post receive_internal_transfer_shipment_path(shipment.internal_transfer, shipment)

    refute shipment.reload.recebido?
  end

  test 'the requester can cancel a still open shipment even without managing that store' do
    shipment = build_transfer

    sign_in @requester
    post cancel_internal_transfer_shipment_path(shipment.internal_transfer, shipment)

    assert shipment.reload.cancelado?
  end

  test 'an unrelated user cannot cancel it' do
    shipment = build_transfer
    unrelated = gerente('rj')

    sign_in unrelated
    post cancel_internal_transfer_shipment_path(shipment.internal_transfer, shipment)

    refute shipment.reload.cancelado?
  end

  test 'cancelling a reserved shipment returns the stock and requires the origin manager or an admin' do
    shipment = build_transfer(status: :reservado)
    stub_adjust

    sign_in gerente('lagoa_seca')
    post cancel_internal_transfer_shipment_path(shipment.internal_transfer, shipment)
    refute shipment.reload.cancelado?, 'gerente do destino não pode cancelar uma remessa já reservada'

    sign_in gerente('bh_shopping')
    post cancel_internal_transfer_shipment_path(shipment.internal_transfer, shipment)
    assert shipment.reload.cancelado?
  end

  test 'a shipment of another transfer returns 404' do
    shipment = build_transfer
    other_transfer = build_transfer

    post reserve_internal_transfer_shipment_path(other_transfer.internal_transfer, shipment)

    assert_response :not_found
  end
end
