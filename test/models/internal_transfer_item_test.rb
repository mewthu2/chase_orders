require 'test_helper'

class InternalTransferItemTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(name: 'Solicitante', email: 'solicitante_item@example.com', password: 'password123')
    @destination = Location.create!(slug: 'lagoa_seca', name: 'Lagoa Seca', shopify_location_id: '1')
    @origin = Location.create!(slug: 'bh_shopping', name: 'BH Shopping', shopify_location_id: '2')
    @transfer = InternalTransfer.new(destination_location: @destination, requested_by: @user)
    @shipment = @transfer.shipments.build(origin_location: @origin)
  end

  test 'quantity must be a positive integer' do
    linked = Product.create!(sku: 'A', shopify_product_name: 'A', shopify_inventory_item_id: '1')
    [0, -1].each do |quantity|
      item = @shipment.items.build(product: linked, quantity: quantity)
      refute item.valid?, "#{quantity} deveria ser inválido"
    end
  end

  test 'a product without the Shopify inventory item id is refused with its SKU' do
    unlinked = Product.create!(sku: 'SEM-ID', shopify_product_name: 'Sem vínculo')
    item = @shipment.items.build(product: unlinked, quantity: 1)

    refute item.valid?
    assert_match(/SEM-ID/, item.errors.full_messages.to_sentence)
  end

  test 'the same product cannot repeat within the same shipment' do
    linked = Product.create!(sku: 'A', shopify_product_name: 'A', shopify_inventory_item_id: '1')
    @shipment.items.build(product: linked, quantity: 1)
    @shipment.items.build(product: linked, quantity: 2)

    refute @transfer.valid?
    assert_match(/já está na lista/, @transfer.errors.full_messages.to_sentence)
  end

  test 'pending and failed items are not locked; reserved, received and cancelled are' do
    linked = Product.create!(sku: 'A', shopify_product_name: 'A', shopify_inventory_item_id: '1')
    item = @shipment.items.build(product: linked, quantity: 1)

    refute item.locked?
    item.status = :failed
    refute item.locked?
    item.status = :reserved
    assert item.locked?
    item.status = :received
    assert item.locked?
    item.status = :cancelled
    assert item.locked?
  end
end
