require 'test_helper'

class B2bCatalogTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(name: 'Catalogo', email: 'catalogo_model@example.com', password: 'password123')
    Product.create!(sku: 'LEG-ASH-G', shopify_product_name: 'Legging Apex Seamless Ash', option1: 'G', shopify_product_id: '1', image_url: 'https://img/ash.jpg')
    Product.create!(sku: 'LEG-ASH-P', shopify_product_name: 'Legging Apex Seamless Ash', option1: 'P', shopify_product_id: '1')
    Product.create!(sku: 'LEG-ASH-M', shopify_product_name: 'Legging Apex Seamless Ash', option1: 'M', shopify_product_id: '1')
  end

  def build_catalog(**attrs)
    B2bCatalog.create!({ title: 'Verão', user: @user, products_attributes: [
      { style_name: 'Legging Apex Seamless', color_name: 'Ash', position: 0, skus: %w[LEG-ASH-G LEG-ASH-P LEG-ASH-M] }
    ] }.merge(attrs))
  end

  test 'creates a public token and variants ordered by size from the given skus' do
    catalog = build_catalog
    product = catalog.products.first

    assert catalog.public_token.length >= 32
    assert_equal %w[P M G], product.variants.map(&:size)
    assert_equal '1', product.shopify_product_id
    assert_equal ['https://img/ash.jpg'], product.image_urls
    assert product.variants.all?(&:sold_out?)
  end

  test 'regenerate_public_token! changes the link' do
    catalog = build_catalog
    old = catalog.public_token
    catalog.regenerate_public_token!
    refute_equal old, catalog.reload.public_token
  end

  test 'a client catalog needs a client and a general one drops it' do
    refute B2bCatalog.new(title: 'X', user: @user, kind: :client).valid?
    client = Client.create!(responsible_name: 'Loja', registration: '25.405.327/0001-74')
    general = B2bCatalog.create!(title: 'Y', user: @user, kind: :general, client: client)
    assert_nil general.client
  end

  test 'styles groups colors by style keeping position order' do
    catalog = build_catalog
    catalog.products.create!(style_name: 'Top Harmony', color_name: 'Pink', position: 1, skus: [])

    assert_equal ['Legging Apex Seamless', 'Top Harmony'], catalog.styles.map(&:first)
  end

  test 'quantity_error refuses variants of other catalogs and quantities above available' do
    catalog = build_catalog
    variant = catalog.variants.first
    variant.update!(available: 3, availability: :low)

    assert_nil catalog.quantity_error(variant.id => 3)
    assert_match(/acima do disponível/, catalog.quantity_error(variant.id => 4))
    assert_match(/fora deste catálogo/, catalog.quantity_error(999_999 => 1))
  end

  test 'availability_for maps quantities to levels' do
    assert_equal :sold_out, B2bCatalogVariant.availability_for(0)
    assert_equal :low, B2bCatalogVariant.availability_for(5)
    assert_equal :available, B2bCatalogVariant.availability_for(6)
  end

  test 'removing a color removes its order items' do
    catalog = build_catalog
    order = catalog.catalog_orders.create!(customer_name: 'Loja', customer_registration: '25.405.327/0001-74')
    order.replace_items!({ catalog.variants.first.id => 1 }, edited_by: 'customer')

    catalog.update!(products_attributes: [{ id: catalog.products.first.id, _destroy: '1' }])

    assert_equal 0, order.items.reload.count
  end
end
