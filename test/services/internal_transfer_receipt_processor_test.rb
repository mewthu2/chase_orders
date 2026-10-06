require 'test_helper'
require 'webmock/minitest'

class InternalTransferReceiptProcessorTest < ActiveSupport::TestCase
  GRAPHQL_URL = 'https://chasebrasil.myshopify.com/admin/api/2025-01/graphql.json'.freeze

  def setup
    ENV['CHASE_ORDERS_TOKEN'] = 'fake-shopify-token'
    @requester = User.create!(name: 'Solicitante', email: 'solicitante_rec@example.com', password: 'password123')
    @user = User.create!(name: 'Gerente Destino', email: 'gerente_destino@example.com', password: 'password123')
    @destination = Location.create!(slug: 'lagoa_seca', name: 'Lagoa Seca', shopify_location_id: '111')
    @origin = Location.create!(slug: 'bh_shopping', name: 'BH Shopping', shopify_location_id: '222')
    @a = Product.create!(sku: 'A', shopify_product_name: 'Produto A', shopify_inventory_item_id: '9001', stock_lagoa_seca: '5')
    @b = Product.create!(sku: 'B', shopify_product_name: 'Produto B', shopify_inventory_item_id: '9002', stock_lagoa_seca: '0')
    @graphql_calls = []
  end

  def sent_shipment(items)
    transfer = InternalTransfer.new(destination_location: @destination, requested_by: @requester, approval_status: :aprovada)
    shipment = transfer.shipments.build(origin_location: @origin)
    items.each { |product, quantity| shipment.items.build(product: product, quantity: quantity) }
    transfer.save!
    shipment.items.each { |item| item.update!(status: :reserved, reserved_at: Time.current, available_before: 10) }
    shipment.update!(status: :enviado, tracking_code: 'BR123456789BR')
    shipment
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

  test 'credits the destination in Shopify with a positive delta and marks the shipment received' do
    shipment = sent_shipment([[@a, 2], [@b, 1]])
    stub_adjust

    summary = InternalTransferReceiptProcessor.call(shipment, user: @user)

    assert_equal 2, summary.received
    assert_equal 0, summary.failed
    call = @graphql_calls.first
    assert_equal 'gid://shopify/Location/111', call['changes'].first['locationId']
    assert_equal({ 'gid://shopify/InventoryItem/9001' => 2, 'gid://shopify/InventoryItem/9002' => 1 },
                 call['changes'].to_h { |c| [c['inventoryItemId'], c['delta']] })
    assert shipment.reload.recebido?
    assert_not_nil shipment.received_at
    assert_equal @user, shipment.received_by
  end

  test 'increases the local stock of the product at the destination' do
    shipment = sent_shipment([[@a, 2]])
    stub_adjust

    InternalTransferReceiptProcessor.call(shipment, user: @user)

    assert_equal '7', @a.reload.stock_lagoa_seca
  end

  test 'a shipment that is not sent cannot be received' do
    shipment = sent_shipment([[@a, 1]])
    shipment.update!(status: :reservado)
    stub = stub_adjust

    assert_raises(InternalTransferReceiptProcessor::Error) { InternalTransferReceiptProcessor.call(shipment, user: @user) }
    assert_not_requested stub
  end

  test 'a rejection from Shopify on one line still receives the others and keeps the shipment open for retry' do
    shipment = sent_shipment([[@a, 2], [@b, 1]])
    stub_adjust(user_errors: lambda { |input|
      bad = input['changes'].any? { |c| c['inventoryItemId'].end_with?('9002') }
      bad ? [{ field: [], message: 'Location de destino inválida' }] : []
    })

    InternalTransferReceiptProcessor.call(shipment, user: @user)

    assert shipment.items.find_by(product: @a).received?
    bad = shipment.items.find_by(product: @b)
    assert bad.reserved?
    assert_match(/Location de destino inválida/, bad.error_message)
    assert shipment.reload.enviado?, 'a remessa continua enviada para permitir tentar de novo'
  end

  test 'retrying only receives what is still pending, never crediting a line twice' do
    shipment = sent_shipment([[@a, 2], [@b, 1]])
    fail_b = true
    stub_adjust(user_errors: lambda { |input|
      bad = fail_b && input['changes'].any? { |c| c['inventoryItemId'].end_with?('9002') }
      bad ? [{ field: [], message: 'x' }] : []
    })

    InternalTransferReceiptProcessor.call(shipment, user: @user)
    assert shipment.items.find_by(product: @a).received?
    assert shipment.items.find_by(product: @b).reserved?
    calls_after_first = @graphql_calls.size

    fail_b = false
    InternalTransferReceiptProcessor.call(shipment.reload, user: @user)

    assert_equal calls_after_first + 1, @graphql_calls.size, 'só a linha pendente (9002) é enviada de novo'
    assert_equal ['gid://shopify/InventoryItem/9002'], @graphql_calls.last['changes'].map { |c| c['inventoryItemId'] }
    assert shipment.reload.recebido?
  end

  test 'a network failure leaves the lines reserved and reports the error' do
    shipment = sent_shipment([[@a, 1]])
    stub_request(:post, GRAPHQL_URL).to_timeout

    InternalTransferReceiptProcessor.call(shipment, user: @user)

    assert shipment.items.first.reload.reserved?
    assert shipment.items.first.error_message.present?
  end

  test 'a timeline event is recorded for the receipt' do
    shipment = sent_shipment([[@a, 1]])
    stub_adjust

    assert_difference 'InternalTransferEvent.count', 1 do
      InternalTransferReceiptProcessor.call(shipment, user: @user)
    end

    event = InternalTransferEvent.last
    assert_equal 'received', event.action
    assert_equal @user, event.user
  end
end
