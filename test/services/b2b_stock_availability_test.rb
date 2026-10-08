require 'test_helper'
require 'webmock/minitest'
require 'minitest/mock'

class B2bStockAvailabilityTest < ActiveSupport::TestCase
  def setup
    ENV['CORREIOS_ESTOQUE'] = 'https://correios-log.example.com/estoque/'
    ENV['CORREIOS_CARTAO_POSTAGEM_2'] = 'fake-cartao-2'
    ENV['TOKEN_LOG_PRODUCTION2'] = 'fake-token-2'
  end

  def stub_stock(sku, disponivel)
    stub_request(:get, "https://correios-log.example.com/estoque/#{sku}/estoque")
      .to_return(status: 200, body: { disponivel: disponivel }.to_json)
  end

  test 'available is Correios stock minus the B2B reservation' do
    stub_stock('LEG-A', 3)
    StockReservation.create!(account: :b2b, tiny_order_id: '1', sku: 'LEG-A', quantity: 4)
    StockReservation.create!(account: :b2c, tiny_order_id: '2', sku: 'LEG-A', quantity: 50)

    result = B2bStockAvailability.for_sku('leg-a')

    assert_equal [3, 4, -1, 'out'], [result.stock, result.reserved, result.available, result.status]
  end

  test 'Correios failure gives an error result' do
    stub_request(:get, 'https://correios-log.example.com/estoque/LEG-A/estoque').to_return(status: 500)

    assert B2bStockAvailability.for_sku('LEG-A').error?
  end

  test 'shortages sums repeated skus and ignores items marked for destruction' do
    stub_stock('LEG-A', 5)
    StockReservation.create!(account: :b2b, tiny_order_id: '1', sku: 'LEG-A', quantity: 2)
    items = [B2bOrderItem.new(sku: 'LEG-A', quantity: 2), B2bOrderItem.new(sku: 'leg-a', quantity: 2)]
    removed = B2bOrderItem.new(sku: 'LEG-A', quantity: 50)
    removed.mark_for_destruction

    shortages = B2bStockAvailability.shortages(items + [removed])

    assert_equal [{ sku: 'LEG-A', requested: 4, stock: 5, reserved: 2, available: 3 }], shortages
  end

  test 'shortages ignores skus whose stock could not be read' do
    stub_request(:get, 'https://correios-log.example.com/estoque/LEG-A/estoque').to_timeout

    assert_empty B2bStockAvailability.shortages([B2bOrderItem.new(sku: 'LEG-A', quantity: 99)])
  end

  test 'shortages looks up the Correios stock of many skus concurrently' do
    skus = (1..6).map { |i| "SKU-#{i}" }
    skus.each do |sku|
      stub_request(:get, "https://correios-log.example.com/estoque/#{sku}/estoque")
        .to_return(lambda { |_| sleep 0.3; { status: 200, body: { disponivel: 1 }.to_json } })
    end
    items = skus.map { |sku| B2bOrderItem.new(sku:, quantity: 2) }

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    shortages = B2bStockAvailability.shortages(items)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal skus, shortages.map { |s| s[:sku] }
    assert_operator elapsed, :<, 1.0
  end

  test 'Correios stock lookups use a short timeout' do
    captured = nil
    fake = Struct.new(:success?, :body).new(true, { disponivel: 4 }.to_json)
    HTTParty.stub(:get, ->(_url, options) { captured = options; fake }) do
      assert_equal 4, B2bStockAvailability.for_sku('LEG-A').stock
    end

    assert_equal B2bStockAvailability::CORREIOS_TIMEOUT, captured[:timeout]
  end
end
