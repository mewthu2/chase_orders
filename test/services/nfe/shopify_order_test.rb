require 'test_helper'
require 'webmock/minitest'
require 'minitest/mock'
require_relative '../../support/shopify_order_factory'

class Nfe::ShopifyOrderTest < ActiveSupport::TestCase
  def setup
    Rails.cache.clear
    stub_request(:get, 'https://viacep.com.br/ws/30140071/json/')
      .to_return(status: 200, headers: { 'Content-Type' => 'application/json' },
                 body: { cep: '30140-071', logradouro: 'Rua das Flores', bairro: 'Funcionários',
                         localidade: 'Belo Horizonte', uf: 'MG', ibge: '3106200' }.to_json)
  end

  def order(node = ShopifyOrderFactory.node)
    Nfe::ShopifyOrder.new(node)
  end

  test 'recipient comes from the checkout attributes, with the IBGE code from the zip' do
    r = order.recipient
    assert_equal 'Maria Cliente', r[:name]
    assert_equal '52998224725', r[:document]
    assert_equal 'Rua das Flores', r[:street]
    assert_equal '10', r[:number]
    assert_equal 'Apto 2', r[:complement]
    assert_equal 'Funcionários', r[:neighbourhood]
    assert_equal 'MG', r[:state]
    assert_equal '30140071', r[:zip]
    assert_equal '3106200', r[:city_ibge_code]
    assert_equal 9, r[:ie_indicator]
  end

  test 'falls back to the tax credential localized field when there is no CPF attribute' do
    node = ShopifyOrderFactory.node
    node['customAttributes'] = node['customAttributes'].reject { |a| a['key'] == 'additional_cpf_cnpj' }
    node['localizedFields'] = { 'nodes' => [{ 'key' => 'TAX_CREDENTIAL_BR', 'value' => '529.982.247-25' }] }
    assert_equal '52998224725', order(node).document
  end

  test 'items carry the allocated discount, and totals include freight' do
    items = order.items
    assert_equal 2, items.size
    assert_equal BigDecimal('20'), items[0][:discount]
    assert_equal BigDecimal('100'), items[0][:unit_price]
    assert_equal BigDecimal('15'), order.freight
    assert_equal BigDecimal('245'), order.total
  end

  test 'removed lines are skipped and partial returns keep a proportional discount' do
    node = ShopifyOrderFactory.node
    node['lineItems']['nodes'][0]['currentQuantity'] = 1
    node['lineItems']['nodes'][1]['currentQuantity'] = 0
    items = order(node).items
    assert_equal 1, items.size
    assert_equal 1, items[0][:quantity]
    assert_equal BigDecimal('10'), items[0][:discount]
  end

  test 'payment is suggested from the checkout attributes' do
    assert_equal({ method: '03', installments: 3, description: 'mercado pago' }, order.payment)

    pix = ShopifyOrderFactory.attribute(ShopifyOrderFactory.node, 'payment_method', 'pix')
    pix = ShopifyOrderFactory.attribute(pix, 'payment_type', 'bank_transfer')
    assert_equal '17', order(pix).payment[:method]
  end

  test 'store sales that already have an NFC-e and cancelled orders are blocked' do
    pos = ShopifyOrderFactory.attribute(ShopifyOrderFactory.node, 'nfce-key', '3126' + '0' * 40)
    assert_match(/NFC-e/, order(pos).blocking_issues.join)

    cancelled = ShopifyOrderFactory.node('cancelledAt' => '2026-10-27T12:00:00-03:00')
    assert_match(/cancelado/, order(cancelled).blocking_issues.join)
    assert_empty order.blocking_issues
  end

  test 'find searches by order number or by Shopify id' do
    queries = []
    fetch = ->(query) { queries << query; ShopifyOrderFactory.node }
    Nfe::ShopifyOrder.stub(:fetch_node, fetch) do
      Nfe::ShopifyOrder.find('#1001')
      Nfe::ShopifyOrder.find('6100000000001')
    end
    assert_equal ['name:#1001', 'id:6100000000001'], queries

    Nfe::ShopifyOrder.stub(:fetch_node, nil) do
      assert_raises(Nfe::ShopifyOrder::NotFound) { Nfe::ShopifyOrder.find('999') }
    end
  end
end
