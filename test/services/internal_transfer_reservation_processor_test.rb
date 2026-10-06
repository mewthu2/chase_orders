require 'test_helper'
require 'webmock/minitest'

class InternalTransferReservationProcessorTest < ActiveSupport::TestCase
  GRAPHQL_URL = 'https://chasebrasil.myshopify.com/admin/api/2025-01/graphql.json'.freeze
  LEVELS_URL = %r{\Ahttps://chasebrasil\.myshopify\.com/admin/api/2025-01/inventory_levels\.json}

  def setup
    ENV['CHASE_ORDERS_TOKEN'] = 'fake-shopify-token'
    @user = User.create!(name: 'Gerente Origem', email: 'gerente_origem@example.com', password: 'password123')
    @destination = Location.create!(slug: 'lagoa_seca', name: 'Lagoa Seca', shopify_location_id: '111')
    @origin = Location.create!(slug: 'bh_shopping', name: 'BH Shopping', shopify_location_id: '222')
    @a = Product.create!(sku: 'A', shopify_product_name: 'Produto A', shopify_inventory_item_id: '9001', stock_bh_shopping: '10')
    @b = Product.create!(sku: 'B', shopify_product_name: 'Produto B', shopify_inventory_item_id: '9002', stock_bh_shopping: '3')
    @requester = User.create!(name: 'Solicitante', email: 'solicitante_res@example.com', password: 'password123')
    @graphql_calls = []
  end

  def shipment_with(items)
    transfer = InternalTransfer.new(destination_location: @destination, requested_by: @requester, approval_status: :aprovada)
    shipment = transfer.shipments.build(origin_location: @origin)
    items.each { |product, quantity| shipment.items.build(product: product, quantity: quantity) }
    transfer.save!
    shipment
  end

  def stub_levels(available)
    stub_request(:get, LEVELS_URL).to_return do |request|
      query = Addressable::URI.parse(request.uri).query_values
      rows = query['inventory_item_ids'].split(',').filter_map do |id|
        quantity = available[id]
        { inventory_item_id: id.to_i, location_id: query['location_ids'].to_i, available: quantity } unless quantity == :missing
      end
      { body: { inventory_levels: rows }.to_json, headers: { 'Content-Type' => 'application/json' } }
    end
  end

  def stub_adjust(user_errors: nil)
    stub_request(:post, GRAPHQL_URL).to_return do |request|
      input = JSON.parse(request.body)['variables']['input']
      @graphql_calls << input
      errors = user_errors&.call(input) || []
      data = { inventoryAdjustQuantities: { userErrors: errors, inventoryAdjustmentGroup: errors.empty? ? { id: "gid://shopify/InventoryAdjustmentGroup/#{@graphql_calls.size}" } : nil } }
      { body: { data: data }.to_json, headers: { 'Content-Type' => 'application/json' } }
    end
  end

  test 'reserves debiting the origin in Shopify with a negative delta and marks the shipment reserved' do
    shipment = shipment_with([[@a, 2], [@b, 1]])
    stub_levels('9001' => 10, '9002' => 3)
    stub_adjust

    summary = InternalTransferReservationProcessor.call(shipment, user: @user)

    assert_equal 2, summary.reserved
    assert_equal 0, summary.failed
    call = @graphql_calls.first
    assert_equal 'gid://shopify/Location/222', call['changes'].first['locationId']
    assert_equal({ 'gid://shopify/InventoryItem/9001' => -2, 'gid://shopify/InventoryItem/9002' => -1 },
                 call['changes'].to_h { |c| [c['inventoryItemId'], c['delta']] })
    assert shipment.reload.reservado?
    assert_not_nil shipment.reserved_at
    assert_equal @user, shipment.reserved_by
    assert shipment.items.all?(&:reserved?)
  end

  test 'decrements the local stock of the product at the origin' do
    shipment = shipment_with([[@a, 2]])
    stub_levels('9001' => 10)
    stub_adjust

    InternalTransferReservationProcessor.call(shipment, user: @user)

    assert_equal '8', @a.reload.stock_bh_shopping
  end

  test 'a line above the available stock is not reserved and the others still go through' do
    shipment = shipment_with([[@a, 2], [@b, 5]])
    stub_levels('9001' => 10, '9002' => 3)
    stub_adjust

    summary = InternalTransferReservationProcessor.call(shipment, user: @user)

    assert_equal 1, summary.reserved
    assert_equal 1, summary.failed
    assert shipment.reload.aberto?
    failed = shipment.items.find_by(product: @b)
    assert failed.failed?
    assert_match(/Estoque insuficiente.*disponível 3.*retirada 5/, failed.error_message)
  end

  test 'a product missing or untracked at the origin is reported' do
    shipment = shipment_with([[@a, 1], [@b, 1]])
    stub_levels('9001' => :missing, '9002' => nil)
    stub_adjust

    InternalTransferReservationProcessor.call(shipment, user: @user)

    assert_match(/não encontrado/, shipment.items.find_by(product: @a).error_message)
    assert_match(/não rastreado/, shipment.items.find_by(product: @b).error_message)
  end

  test 'a rejected group is retried line by line so the good ones still go through' do
    shipment = shipment_with([[@a, 2], [@b, 1]])
    stub_levels('9001' => 10, '9002' => 3)
    stub_adjust(user_errors: lambda { |input|
      bad = input['changes'].any? { |c| c['inventoryItemId'].end_with?('9002') }
      bad ? [{ field: [], message: 'Item não rastreado' }] : []
    })

    InternalTransferReservationProcessor.call(shipment, user: @user)

    assert shipment.items.find_by(product: @a).reserved?
    bad = shipment.items.find_by(product: @b)
    assert bad.failed?
    assert_match(/Item não rastreado/, bad.error_message)
  end

  test 'retrying only reserves what is still pending or failed, never twice' do
    shipment = shipment_with([[@a, 2], [@b, 5]])
    stub_levels('9001' => 10, '9002' => 3)
    stub_adjust
    InternalTransferReservationProcessor.call(shipment, user: @user)
    assert_equal 1, @graphql_calls.size

    stub_levels('9002' => 9) # estoque de B foi reposto
    InternalTransferReservationProcessor.call(shipment.reload, user: @user)

    assert_equal 2, @graphql_calls.size
    assert_equal ['gid://shopify/InventoryItem/9002'], @graphql_calls.last['changes'].map { |c| c['inventoryItemId'] }
    assert shipment.reload.reservado?
  end

  test 'a shipment that is not reservable is refused and Shopify is not called' do
    shipment = shipment_with([[@a, 1]])
    shipment.update!(status: :recebido)
    stub = stub_adjust

    assert_raises(InternalTransferReservationProcessor::Error) { InternalTransferReservationProcessor.call(shipment, user: @user) }
    assert_not_requested stub
  end

  test 'an origin without a Shopify id fails all lines instead of guessing a location' do
    orphan = Location.create!(slug: 'nova', name: 'Nova', shopify_location_id: nil)
    transfer = InternalTransfer.new(destination_location: @destination, requested_by: @requester, approval_status: :aprovada)
    shipment = transfer.shipments.build(origin_location: orphan)
    shipment.items.build(product: @a, quantity: 1)
    transfer.save!
    stub = stub_adjust

    InternalTransferReservationProcessor.call(shipment, user: @user)

    assert_not_requested stub
    assert_match(/sem ID do Shopify/, shipment.items.first.error_message)
  end

  test 'a Shopify read failure marks the lines as failed instead of raising' do
    shipment = shipment_with([[@a, 1]])
    stub_request(:get, LEVELS_URL).to_return(status: 500, body: 'erro')

    InternalTransferReservationProcessor.call(shipment, user: @user)

    assert shipment.items.first.reload.failed?
  end

  test 'a timeline event is recorded for the reservation' do
    shipment = shipment_with([[@a, 2]])
    stub_levels('9001' => 10)
    stub_adjust

    assert_difference 'InternalTransferEvent.count', 1 do
      InternalTransferReservationProcessor.call(shipment, user: @user)
    end

    event = InternalTransferEvent.last
    assert_equal 'reserved', event.action
    assert_equal @user, event.user
    assert_equal shipment, event.internal_transfer_shipment
  end
end
