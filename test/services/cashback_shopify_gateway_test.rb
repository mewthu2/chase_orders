require 'test_helper'
require 'webmock/minitest'

class CashbackShopifyGatewayTest < ActiveSupport::TestCase
  self.fixture_table_names = []
  URL = 'https://chasebrasil.myshopify.com/admin/api/2026-07/graphql.json'

  setup do
    @gateway = Cashback::ShopifyGateway.new
    @previous_token = ENV['CHASE_ORDERS_TOKEN']
    ENV['CHASE_ORDERS_TOKEN'] = 'test-token'
  end
  teardown { ENV['CHASE_ORDERS_TOKEN'] = @previous_token }

  test 'lookup uses variables, a supported version and the existing Honey credential' do
    stub = stub_request(:post, URL).with do |request|
      body = JSON.parse(request.body)
      request.headers['X-Shopify-Access-Token'] == 'test-token' && body['variables'] == { 'code' => 'MTZA' } && body['query'].include?('$code')
    end.to_return(body: { data: { codeDiscountNodeByCode: nil } }.to_json, headers: { 'Content-Type' => 'application/json' })
    assert_nil @gateway.lookup('MTZA')
    assert_requested stub
  end

  test 'HTTP and GraphQL errors and malformed responses are never successful' do
    [
      { status: 403, body: '{}' },
      { status: 200, body: { errors: [{ message: 'Access denied' }] }.to_json },
      { status: 200, body: 'not json' },
      { status: 200, body: { data: {} }.to_json }
    ].each do |response|
      stub_request(:post, URL).to_return(**response, headers: { 'Content-Type' => 'application/json' })
      assert_raises(Cashback::ShopifyGateway::Error) { @gateway.lookup('MTZA') }
    end
  end

  test 'mutation must include empty userErrors and a returned ID' do
    [
      { userErrors: [{ field: ['id'], message: 'Not found' }], codeDiscountNode: nil },
      { userErrors: [], codeDiscountNode: nil },
      { codeDiscountNode: { id: '123' } }, nil
    ].each do |payload|
      stub_request(:post, URL).to_return(body: { data: { discountCodeDeactivate: payload } }.to_json, headers: { 'Content-Type' => 'application/json' })
      assert_raises(Cashback::ShopifyGateway::Error) { @gateway.deactivate('123') }
    end
  end
end
