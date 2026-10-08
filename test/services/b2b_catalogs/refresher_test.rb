require 'test_helper'
require 'webmock/minitest'
require 'minitest/mock'

class B2bCatalogs::RefresherTest < ActiveSupport::TestCase
  def setup
    ENV['CORREIOS_ESTOQUE'] = 'https://correios-log.example.com/estoque/'
    ENV['CORREIOS_CARTAO_POSTAGEM_2'] = 'fake-cartao-2'
    ENV['TOKEN_LOG_PRODUCTION2'] = 'fake-token-2'
    user = User.create!(name: 'Refresh', email: 'refresh_cat@example.com', password: 'password123')
    Product.create!(sku: 'A-P', shopify_product_name: 'Top A Black', option1: 'P', shopify_product_id: '77')
    Product.create!(sku: 'A-M', shopify_product_name: 'Top A Black', option1: 'M', shopify_product_id: '77')
    @catalog = B2bCatalog.create!(title: 'Geral', user: user, products_attributes: [{ style_name: 'Top A', color_name: 'Black', skus: %w[A-P A-M] }])
    @closed = B2bCatalog.create!(title: 'Fechado', user: user, status: :closed, products_attributes: [{ style_name: 'Top A', color_name: 'Black', skus: %w[A-P] }])
  end

  def stub_stock(sku, disponivel, status: 200)
    stub_request(:get, "https://correios-log.example.com/estoque/#{sku}/estoque")
      .to_return(status:, body: { disponivel: disponivel }.to_json)
  end

  def variant(sku, catalog = @catalog) = catalog.variants.find_by(sku:)

  test 'writes available and level for every sku of active catalogs, minus the queue reservation' do
    stub_stock('A-P', 10)
    stub_stock('A-M', 0)
    StockReservation.create!(account: :b2b, tiny_order_id: '1', sku: 'A-P', quantity: 6)

    B2bCatalogs::ShopifyImages.stub(:fetch, []) { B2bCatalogs::Refresher.call }

    assert_equal [4, 'low'], [variant('A-P').available, variant('A-P').availability]
    assert_equal [0, 'sold_out'], [variant('A-M').available, variant('A-M').availability]
    assert @catalog.reload.stock_refreshed_at.present?
    assert_nil @closed.reload.stock_refreshed_at
  end

  test 'a Correios failure keeps the previous stock' do
    variant('A-P').update!(available: 8, availability: :available)
    stub_stock('A-P', 0, status: 500)
    stub_stock('A-M', 20)

    B2bCatalogs::ShopifyImages.stub(:fetch, []) { B2bCatalogs::Refresher.call }

    assert_equal 8, variant('A-P').available
    assert_equal 'available', variant('A-M').availability
  end

  test 'stores every Shopify image and keeps the old ones when Shopify returns nothing' do
    stub_stock('A-P', 1)
    stub_stock('A-M', 1)
    product = @catalog.products.first
    product.update!(image_urls: ['https://old.jpg'])

    B2bCatalogs::ShopifyImages.stub(:fetch, ['https://a.jpg', 'https://b.jpg']) { B2bCatalogs::Refresher.call }
    assert_equal ['https://a.jpg', 'https://b.jpg'], product.reload.image_urls

    B2bCatalogs::ShopifyImages.stub(:fetch, []) { B2bCatalogs::Refresher.call }
    assert_equal ['https://a.jpg', 'https://b.jpg'], product.reload.image_urls
  end

  test 'ShopifyImages returns the image srcs in position order and [] on failure' do
    body = { 'product' => { 'images' => [{ 'src' => 'https://2.jpg', 'position' => 2 }, { 'src' => 'https://1.jpg', 'position' => 1 }] } }
    client = Object.new
    client.define_singleton_method(:get) { |**| Struct.new(:body).new(body) }

    Shopify::Products.stub(:client_shopify_rest, client) do
      assert_equal ['https://1.jpg', 'https://2.jpg'], B2bCatalogs::ShopifyImages.fetch('77')
    end

    failing = Object.new
    failing.define_singleton_method(:get) { |**| raise StandardError, 'boom' }
    Shopify::Products.stub(:client_shopify_rest, failing) do
      assert_equal [], B2bCatalogs::ShopifyImages.fetch('77')
    end
  end

  test 'the job can refresh a single catalog' do
    stub_stock('A-P', 9)
    stub_stock('A-M', 9)

    B2bCatalogs::ShopifyImages.stub(:fetch, []) { B2bCatalogRefreshJob.perform_now(@catalog.id) }

    assert_equal 9, variant('A-P').available
  end
end
