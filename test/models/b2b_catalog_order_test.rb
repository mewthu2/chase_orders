require 'test_helper'

class B2bCatalogOrderTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(name: 'Encomenda', email: 'encomenda_model@example.com', password: 'password123')
    Product.create!(sku: 'A-P', shopify_product_name: 'Top A Black', option1: 'P')
    Product.create!(sku: 'A-M', shopify_product_name: 'Top A Black', option1: 'M')
    @catalog = B2bCatalog.create!(title: 'Geral', user: @user, products_attributes: [{ style_name: 'Top A', color_name: 'Black', skus: %w[A-P A-M] }])
  end

  test 'registration is stored as digits and must be a valid CNPJ on general catalogs' do
    order = @catalog.catalog_orders.create!(customer_name: 'Loja', customer_registration: '25.405.327/0001-74')
    assert_equal '25405327000174', order.customer_registration
    assert order.pending?
    assert order.edit_token.present?

    bad = @catalog.catalog_orders.new(customer_name: 'Loja', customer_registration: '25.405.327/0001-75')
    refute bad.valid?
    assert_includes bad.errors.full_messages.join, 'CNPJ inválido'
  end

  test 'one order per CNPJ in a catalog' do
    @catalog.catalog_orders.create!(customer_name: 'Loja', customer_registration: '25405327000174')
    refute @catalog.catalog_orders.new(customer_name: 'Outra', customer_registration: '25.405.327/0001-74').valid?
  end

  test 'replace_items! keeps only positive quantities of this catalog variants' do
    order = @catalog.catalog_orders.create!(customer_name: 'Loja', customer_registration: '25405327000174')
    p_variant, m_variant = @catalog.variants.to_a

    order.replace_items!({ p_variant.id => 2, m_variant.id => 0, 999_999 => 4 }, edited_by: 'Ana')

    assert_equal [[p_variant.id, 2]], order.items.pluck(:b2b_catalog_variant_id, :quantity)
    assert_equal 'Ana', order.last_edited_by
    assert_equal 2, order.total_pieces
  end

  test 'convert! links the order and blocks edits' do
    order = @catalog.catalog_orders.create!(customer_name: 'Loja', customer_registration: '25405327000174')
    b2b_order = B2bOrder.new(kind: :sale, user: @user, client: Client.create!(responsible_name: 'C'))
    b2b_order.b2b_order_items.build(sku: 'A-P', quantity: 1, price: 1)
    b2b_order.save!

    order.convert!(b2b_order)

    assert order.converted?
    assert_equal b2b_order, order.b2b_order
    refute order.editable?
  end

  test 'matching_client finds the client by CNPJ digits whatever the mask' do
    client = Client.create!(responsible_name: 'Loja Centro', registration: '25.405.327/0001-74')
    order = @catalog.catalog_orders.create!(customer_name: 'Loja', customer_registration: '25405327000174')

    assert_equal client, order.matching_client
  end
end
