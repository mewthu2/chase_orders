require 'test_helper'

class InternalTransferShipmentTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(name: 'Solicitante', email: 'solicitante_shp@example.com', password: 'password123')
    @destination = Location.create!(slug: 'lagoa_seca', name: 'Lagoa Seca', shopify_location_id: '1')
    @origin = Location.create!(slug: 'bh_shopping', name: 'BH Shopping', shopify_location_id: '2')
    @product = Product.create!(sku: 'SKU-1', shopify_product_name: 'Camiseta', shopify_inventory_item_id: '9001')
    @transfer = InternalTransfer.new(destination_location: @destination, requested_by: @user)
    @shipment = @transfer.shipments.build(origin_location: @origin)
    @shipment.items.build(product: @product, quantity: 2)
    @transfer.save!
  end

  test 'starts open, reservable, not sendable, not receivable, cancellable' do
    assert @shipment.aberto?
    assert @shipment.reservable?
    refute @shipment.sendable?
    refute @shipment.receivable?
    assert @shipment.cancellable?
    refute @shipment.returns_stock_on_cancel?
  end

  test 'once reserved it is sendable, still reservable for retrying failed items, and returns stock if cancelled' do
    @shipment.update!(status: :reservado)

    assert @shipment.sendable?
    assert @shipment.cancellable?
    assert @shipment.returns_stock_on_cancel?
  end

  test 'once sent it is receivable and no longer reservable' do
    @shipment.update!(status: :enviado)

    assert @shipment.receivable?
    refute @shipment.reservable?
    assert @shipment.cancellable?
    assert @shipment.returns_stock_on_cancel?
  end

  test 'once received it cannot be cancelled, sent or reserved again' do
    @shipment.update!(status: :recebido)

    refute @shipment.cancellable?
    refute @shipment.sendable?
    refute @shipment.reservable?
  end

  test 'a cancelled shipment cannot be acted upon again' do
    @shipment.update!(status: :cancelado)

    refute @shipment.cancellable?
    refute @shipment.reservable?
    refute @shipment.sendable?
    refute @shipment.receivable?
  end

  test 'reservable? is also true when some items failed (so a retry is possible)' do
    @shipment.items.first.update!(status: :failed, error_message: 'x')

    assert @shipment.reservable?
  end
end
