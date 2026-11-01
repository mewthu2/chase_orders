require 'test_helper'
require 'webmock/minitest'

class WhatsappCustomerContextTest < ActiveSupport::TestCase
  self.fixture_table_names = []
  URL = Whatsapp::ShopifyCustomerContext::ENDPOINT

  setup do
    @gateway = Whatsapp::ShopifyCustomerContext.new
    @previous_token = ENV['CHASE_ORDERS_TOKEN']
    ENV['CHASE_ORDERS_TOKEN'] = 'test-token'
  end
  teardown { ENV['CHASE_ORDERS_TOKEN'] = @previous_token }

  test 'numeric and global customer ids use variables and the existing credential' do
    ['123', 'gid://shopify/Customer/123'].each do |id|
      request = stub_request(:post, URL).with do |request|
        body = JSON.parse(request.body)
        request.headers['X-Shopify-Access-Token'] == 'test-token' &&
          body['variables'] == { 'id' => 'gid://shopify/Customer/123', 'after' => 'next-page' } &&
          body['query'].include?('customer(id: $id)') && body['query'].exclude?('mutation')
      end.to_return(body: payload.to_json, headers: { 'Content-Type' => 'application/json' })

      result = @gateway.orders(id, after: 'next-page')
      assert_equal '279.90', result[:orders].first[:total_price]
      assert_equal 'BRL', result[:orders].first[:currency]
      assert_equal [{ title: 'Calça Azul', quantity: 2 }], result[:orders].first[:items]
      assert_equal true, result[:orders].first[:has_more_items]
      assert_equal({ has_next_page: true, end_cursor: 'next-cursor' }, result[:page_info])
      assert_equal 'https://admin.shopify.com/store/chasebrasil/orders/456', result[:orders].first[:shopify_url]
      assert_requested request
    end
  end

  test 'no orders is distinct from an unrecognized or deleted customer' do
    data = payload
    data[:data][:customer][:orders] = { nodes: [], pageInfo: { hasNextPage: false, endCursor: nil } }
    reply(data)
    assert_empty @gateway.orders('123')[:orders]
    reply(data: { customer: nil })
    error = assert_raises(Whatsapp::ShopifyCustomerContext::Error) { @gateway.orders('123') }
    assert_match(/Cliente vinculado não encontrado/, error.message)
  end

  test 'invalid ids never trigger an API request or a fuzzy search' do
    [nil, '', '0', '-123', '123 OR email:*', 'gid://shopify/Order/123', "123\n", '1' * 21].each do |id|
      assert_raises(Whatsapp::ShopifyCustomerContext::Error) { @gateway.orders(id) }
    end
    assert_not_requested :post, URL
  end

  test 'invalid pagination is rejected before API access' do
    [{ key: 'cursor' }, ['cursor'], 'a' * 2049].each do |cursor|
      assert_raises(ArgumentError) { @gateway.orders('123', after: cursor) }
    end
    assert_not_requested :post, URL
  end

  test 'HTTP GraphQL malformed and partial errors never become an empty order history' do
    [
      { status: 429, body: '{}' },
      { status: 403, body: '{}' },
      { body: { data: { customer: nil }, errors: [{ message: 'Access denied: private detail' }] }.to_json },
      { body: 'not json' },
      { body: { data: {} }.to_json },
      { body: { data: { customer: { id: 'gid://shopify/Customer/999', orders: {} } } }.to_json },
      { body: { data: { customer: { id: 'gid://shopify/Customer/123', orders: { nodes: nil } } } }.to_json }
    ].each do |response|
      stub_request(:post, URL).to_return(**response, headers: { 'Content-Type' => 'application/json' })
      error = assert_raises(Whatsapp::ShopifyCustomerContext::Error) { @gateway.orders('123') }
      assert_not_includes error.message, 'private detail'
    end
  end

  test 'incomplete page info cannot hide further orders' do
    [nil, {}, { hasNextPage: true, endCursor: nil }, { hasNextPage: 'false', endCursor: nil }].each do |page|
      data = payload
      data[:data][:customer][:orders][:pageInfo] = page
      reply(data)
      assert_raises(Whatsapp::ShopifyCustomerContext::Error) { @gateway.orders('123') }
    end
  end

  test 'timeouts and absent credentials are useful errors' do
    stub_request(:post, URL).to_timeout
    assert_raises(Whatsapp::ShopifyCustomerContext::Error) { @gateway.orders('123') }
    ENV.delete('CHASE_ORDERS_TOKEN')
    error = assert_raises(Whatsapp::ShopifyCustomerContext::Error) { @gateway.orders('123') }
    assert_match(/não está configurada/, error.message)
    assert_requested :post, URL, times: 1
  end

  test 'tracking links accept only http or https URLs without credentials' do
    data = payload
    order = data[:data][:customer][:orders][:nodes].first
    order[:fulfillments] = [{ trackingInfo: [
      { company: 'Correios', number: 'AB123', url: 'https://rastreamento.correios.com.br/' },
      { number: 'AB124', url: 'javascript:alert(1)' },
      { number: 'AB125', url: 'https://user:secret@example.com/' },
      { number: 'AB126', url: 'not a URL' }
    ] }]
    reply(data)
    tracking = @gateway.orders('123')[:orders].first[:tracking]
    assert_equal 'https://rastreamento.correios.com.br/', tracking.first[:url]
    assert_equal [nil, nil, nil], tracking.drop(1).map { |t| t[:url] }
    assert_equal 'AB125', tracking[2][:number]
  end

  private

  def reply(data)
    stub_request(:post, URL).to_return(body: data.to_json, headers: { 'Content-Type' => 'application/json' })
  end

  def payload
    { data: { customer: { id: 'gid://shopify/Customer/123', orders: {
      nodes: [{ id: 'gid://shopify/Order/456', name: '#1001', createdAt: '2026-10-30T12:00:00Z',
        displayFinancialStatus: 'PAID', displayFulfillmentStatus: 'FULFILLED',
        totalPriceSet: { shopMoney: { amount: '279.90', currencyCode: 'BRL' } },
        lineItems: { nodes: [{ title: 'Calça Azul', quantity: 2 }], pageInfo: { hasNextPage: true } },
        fulfillments: [] }], pageInfo: { hasNextPage: true, endCursor: 'next-cursor' }
    } } } }
  end
end
