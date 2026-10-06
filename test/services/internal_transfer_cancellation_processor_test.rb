require 'test_helper'
require 'webmock/minitest'

class InternalTransferCancellationProcessorTest < ActiveSupport::TestCase
  GRAPHQL_URL = 'https://chasebrasil.myshopify.com/admin/api/2025-01/graphql.json'.freeze

  def setup
    ENV['CHASE_ORDERS_TOKEN'] = 'fake-shopify-token'
    @requester = User.create!(name: 'Solicitante', email: 'solicitante_cnl@example.com', password: 'password123')
    @user = User.create!(name: 'Gerente', email: 'gerente_cnl@example.com', password: 'password123')
    @destination = Location.create!(slug: 'lagoa_seca', name: 'Lagoa Seca', shopify_location_id: '111')
    @origin = Location.create!(slug: 'bh_shopping', name: 'BH Shopping', shopify_location_id: '222')
    @a = Product.create!(sku: 'A', shopify_product_name: 'Produto A', shopify_inventory_item_id: '9001', stock_bh_shopping: '8')
    @graphql_calls = []
  end

  def build_shipment(items, status: :aberto)
    transfer = InternalTransfer.new(destination_location: @destination, requested_by: @requester, approval_status: :aprovada)
    shipment = transfer.shipments.build(origin_location: @origin)
    items.each { |product, quantity| shipment.items.build(product: product, quantity: quantity) }
    transfer.save!
    shipment.update!(status: status)
    shipment
  end

  def stub_adjust
    stub_request(:post, GRAPHQL_URL).to_return do |request|
      @graphql_calls << JSON.parse(request.body)['variables']['input']
      { body: { data: { inventoryAdjustQuantities: { userErrors: [], inventoryAdjustmentGroup: { id: 'gid://shopify/InventoryAdjustmentGroup/5' } } } }.to_json,
        headers: { 'Content-Type' => 'application/json' } }
    end
  end

  test 'cancelling an open shipment does not touch Shopify (nothing was reserved yet)' do
    shipment = build_shipment([[@a, 2]])
    stub = stub_adjust

    InternalTransferCancellationProcessor.call(shipment, user: @user)

    assert_not_requested stub
    assert shipment.reload.cancelado?
    assert shipment.items.all?(&:cancelled?)
  end

  test 'cancelling a reserved shipment returns the quantity to the origin in Shopify with a positive delta' do
    shipment = build_shipment([[@a, 2]], status: :reservado)
    shipment.items.first.update!(status: :reserved, available_before: 10)
    stub_adjust

    InternalTransferCancellationProcessor.call(shipment, user: @user)

    assert_equal [{ 'inventoryItemId' => 'gid://shopify/InventoryItem/9001', 'locationId' => 'gid://shopify/Location/222', 'delta' => 2 }],
                 @graphql_calls.first['changes']
    assert shipment.items.first.reload.cancelled?
    assert_equal '10', @a.reload.stock_bh_shopping
    assert shipment.reload.cancelado?
    assert_not_nil shipment.cancelled_at
    assert_equal @user, shipment.cancelled_by
  end

  test 'a shipment already received cannot be cancelled and Shopify is not called' do
    shipment = build_shipment([[@a, 1]], status: :recebido)
    stub = stub_adjust

    assert_raises(InternalTransferCancellationProcessor::Error) { InternalTransferCancellationProcessor.call(shipment, user: @user) }
    assert_not_requested stub
  end

  test 'a Shopify rejection leaves the shipment reserved and reports the error' do
    shipment = build_shipment([[@a, 2]], status: :reservado)
    shipment.items.first.update!(status: :reserved, available_before: 10)
    stub_request(:post, GRAPHQL_URL).to_return(body: { data: { inventoryAdjustQuantities: { userErrors: [{ field: [], message: 'Item bloqueado' }] } } }.to_json)

    error = assert_raises(InternalTransferCancellationProcessor::Error) { InternalTransferCancellationProcessor.call(shipment, user: @user) }

    assert_match(/Item bloqueado/, error.message)
    assert shipment.reload.reservado?
    assert shipment.items.first.reload.reserved?
  end

  test 'a timeline event is recorded for the cancellation' do
    shipment = build_shipment([[@a, 1]])

    assert_difference 'InternalTransferEvent.count', 1 do
      InternalTransferCancellationProcessor.call(shipment, user: @user)
    end

    event = InternalTransferEvent.last
    assert_equal 'cancelled', event.action
    assert_equal @user, event.user
  end
end
