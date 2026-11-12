require 'test_helper'
require 'webmock/minitest'
require 'minitest/mock'

class UpdateShopifyStockFromCorreiosBatchJobTest < ActiveJob::TestCase
  STOCK_URL = 'https://correios.example.com/itens/'.freeze

  FakeResponse = Struct.new(:body)

  # Shopify recusa o SKU "RECUSA" e aceita os demais.
  class FakeShopify
    def query(query:, variables:)
      item = variables[:input][:setQuantities].first[:inventoryItemId]
      errors = item.end_with?('/3') ? [{ 'field' => ['quantity'], 'message' => 'Inventory item not stocked' }] : []
      FakeResponse.new({ 'data' => { 'inventorySetOnHandQuantities' => { 'userErrors' => errors } } })
    end
  end

  def setup
    ENV['CORREIOS_ESTOQUE'] = STOCK_URL
    ENV['CHASE_ORDERS_TOKEN'] = 'shpat_test'
    ENV['LOCATION_LOG'] = '123'
    @ok = Product.create!(sku: 'SYNC-OK', shopify_inventory_item_id: '1', shopify_product_name: 'Legging OK')
    @missing = Product.create!(sku: 'SYNC-404', shopify_inventory_item_id: '2', shopify_product_name: 'Top Sumido')
    @refused = Product.create!(sku: 'SYNC-RECUSA', shopify_inventory_item_id: '3', shopify_product_name: 'Short Recusado')
    stub_request(:get, "#{STOCK_URL}SYNC-OK/estoque").to_return(status: 200, body: { disponivel: 7 }.to_json)
    stub_request(:get, "#{STOCK_URL}SYNC-404/estoque").to_return(status: 404, body: { mensagem: 'Item não encontrado' }.to_json)
    stub_request(:get, "#{STOCK_URL}SYNC-RECUSA/estoque").to_return(status: 200, body: { disponivel: 2 }.to_json)
    @attempt = Attempt.create!(kinds: :sync_correios_stock, status: :processing, params: { total: 3, total_batches: 1, processed_batches: 0, success: 0, failed: 0, errors: [], completed_batch_indexes: [] }.to_json)
  end

  test 'every failed product is recorded with where and why it failed' do
    ShopifyAPI::Clients::Graphql::Admin.stub(:new, FakeShopify.new) do
      UpdateShopifyStockFromCorreiosBatchJob.perform_now(@attempt.id, [@ok.id, @missing.id, @refused.id], 1, 1)
    end

    failures = @attempt.stock_sync_failures.order(:sku).to_a
    assert_equal %w[SYNC-404 SYNC-RECUSA], failures.map(&:sku)
    assert_equal 'correios', failures.first.stage
    assert_match(/404.*Item não encontrado/, failures.first.reason)
    assert_equal 'shopify', failures.last.stage
    assert_match(/not stocked/, failures.last.reason)

    summary = JSON.parse(@attempt.reload.params)
    assert_equal [1, 2], [summary['success'], summary['failed']]
  end
end
