require 'test_helper'
require 'webmock/minitest'

class StockReservationRefresherTest < ActiveSupport::TestCase
  SEARCH_URL = 'https://tiny.example.com/pedidos.pesquisa.php'.freeze
  ORDER_URL = 'https://tiny.example.com/pedido.obter.php'.freeze

  def setup
    ENV['PEDIDOS_PESQUISA'] = SEARCH_URL
    ENV['OBTER_PEDIDO'] = ORDER_URL
    ENV['TOKEN_TINY2_PRODUCTION'] = 'tiny2'
    ENV['TOKEN_TINY3_PRODUCTION'] = 'tiny3'
  end

  def summary(id, numero: "N#{id}", numero_ecommerce: nil)
    { pedido: { id: id.to_s, numero: numero, numero_ecommerce: numero_ecommerce, nome: "Cliente #{id}", data_pedido: '07/10/2026' }.compact }
  end

  def stub_queue(token, pedidos, pages: 1, page: 1)
    stub_request(:get, SEARCH_URL)
      .with(query: hash_including(token: token, situacao: 'preparando_envio', pagina: page.to_s))
      .to_return(body: { retorno: { status: 'OK', numero_paginas: pages, pedidos: pedidos } }.to_json)
  end

  def stub_empty_queue(token)
    stub_request(:get, SEARCH_URL).with(query: hash_including(token: token))
      .to_return(body: { retorno: { status: 'Erro', codigo_erro: '20', erros: [{ erro: 'A consulta não retornou registros' }] } }.to_json)
  end

  def stub_order(id, items, **extra)
    stub_request(:get, ORDER_URL).with(query: hash_including(id: id.to_s))
      .to_return(body: { retorno: { status: 'OK', pedido: { id: id.to_s, itens: items.map { |sku, qty| { item: { codigo: sku, quantidade: qty } } } }.merge(extra) } }.to_json)
  end

  test 'stores the shop order number and the invoice of the Tiny order' do
    stub_queue('tiny3', [summary(20, numero_ecommerce: '#5501')])
    stub_order(20, [['LEG-A', '1']], id_nota_fiscal: '880011')

    StockReservationRefresher.call(:b2c)

    row = StockReservation.find_by(tiny_order_id: '20')
    assert_equal ['#5501', '880011'], [row.ecommerce_number, row.invoice_id]
  end

  test 'an order without invoice keeps it blank (Tiny sends 0)' do
    stub_queue('tiny3', [summary(22)])
    stub_order(22, [['LEG-A', '1']], id_nota_fiscal: '0')

    StockReservationRefresher.call(:b2c)

    assert_nil StockReservation.find_by(tiny_order_id: '22').invoice_id
  end

  test 'known orders get the shop order number without fetching the order again' do
    StockReservation.create!(account: :b2c, tiny_order_id: '23', tiny_order_number: 'N23', sku: 'LEG-A', quantity: 1)
    stub_queue('tiny3', [summary(23, numero_ecommerce: '#7007')])

    StockReservationRefresher.call(:b2c)

    assert_equal '#7007', StockReservation.find_by(tiny_order_id: '23').ecommerce_number
    assert_not_requested :get, ORDER_URL, query: hash_including(id: '23')
  end

  test 'stores the items of new queue orders' do
    stub_queue('tiny2', [summary(10)])
    stub_order(10, [['leg-a', '2.00'], ['TOP-B', '1.00']])

    refresh = StockReservationRefresher.call(:b2b)

    assert_equal 'success', refresh.status
    assert refresh.last_refreshed_at.present?
    assert_equal 2, StockReservation.reserved_for('LEG-A', account: :b2b)
    row = StockReservation.find_by(sku: 'TOP-B')
    assert_equal ['10', 'N10', 'Cliente 10', Date.new(2026, 10, 7)], [row.tiny_order_id, row.tiny_order_number, row.customer_name, row.order_date]
  end

  test 'follows every page of the queue' do
    stub_queue('tiny2', [summary(1)], pages: 2, page: 1)
    stub_queue('tiny2', [summary(2)], pages: 2, page: 2)
    stub_order(1, [['A', '1']])
    stub_order(2, [['A', '3']])

    StockReservationRefresher.call(:b2b)

    assert_equal 4, StockReservation.reserved_for('A', account: :b2b)
  end

  test 'orders already created in Correios are not reserved' do
    Attempt.create!(kinds: :create_correios_order_tiny2, status: :success, tiny_order_id: '10')
    stub_queue('tiny2', [summary(10)])

    StockReservationRefresher.call(:b2b)

    assert_equal 0, StockReservation.count
    assert_not_requested :get, ORDER_URL, query: hash_including(id: '10')
  end

  test 'orders with a Correios order number are not reserved even if the attempt is not marked success' do
    stub_queue('tiny2', [summary(30), summary(31)])
    stub_order(31, [['LEG-A', '1']])
    Attempt.insert_all([{ kinds: Attempt.kinds[:create_correios_order_tiny2], status: Attempt.statuses[:fail], tiny_order_id: 30,
                          order_correios_id: 25_135_290, created_at: Time.current, updated_at: Time.current }])

    StockReservationRefresher.call(:b2b)

    assert_equal %w[31], StockReservation.distinct.pluck(:tiny_order_id)
    assert_not_requested :get, ORDER_URL, query: hash_including(id: '30')
  end

  test 'removes orders that left the queue and keeps known ones without refetching' do
    StockReservation.create!(account: :b2b, tiny_order_id: '10', sku: 'A', quantity: 1)
    StockReservation.create!(account: :b2b, tiny_order_id: '99', sku: 'A', quantity: 5)
    StockReservation.create!(account: :b2c, tiny_order_id: '99', sku: 'A', quantity: 7)
    stub_queue('tiny2', [summary(10)])

    StockReservationRefresher.call(:b2b)

    assert_equal ['10'], StockReservation.b2b.pluck(:tiny_order_id)
    assert_equal 7, StockReservation.reserved_for('A', account: :b2c)
    assert_not_requested :get, ORDER_URL
  end

  test 'an empty queue clears the account reservations' do
    StockReservation.create!(account: :b2c, tiny_order_id: '5', sku: 'A', quantity: 1)
    stub_empty_queue('tiny3')

    refresh = StockReservationRefresher.call(:b2c)

    assert_equal 'success', refresh.status
    assert_equal 0, StockReservation.b2c.count
  end

  test 'a failing queue listing keeps the previous snapshot and records the error' do
    StockReservation.create!(account: :b2b, tiny_order_id: '10', sku: 'A', quantity: 1)
    stub_request(:get, /pedidos\.pesquisa/).to_return(body: { retorno: { status: 'Erro', codigo_erro: '1', erros: [{ erro: 'Token inválido' }] } }.to_json)

    refresh = StockReservationRefresher.call(:b2b)

    assert_equal 'error', refresh.status
    assert_match(/Token inválido/, refresh.message)
    assert_equal 1, StockReservation.b2b.count
  end

  test 'rate limit while fetching items keeps what was stored and marks partial' do
    stub_queue('tiny2', [summary(1), summary(2)])
    stub_order(1, [['A', '1']])
    stub_request(:get, ORDER_URL).with(query: hash_including(id: '2'))
      .to_return(body: { retorno: { status: 'Erro', codigo_erro: '6' } }.to_json)

    refresh = StockReservationRefresher.call(:b2b)

    assert_equal 'partial', refresh.status
    assert_equal ['1'], StockReservation.b2b.distinct.pluck(:tiny_order_id)
  end

  test 'one broken order does not stop the others' do
    stub_queue('tiny2', [summary(1), summary(2)])
    stub_request(:get, ORDER_URL).with(query: hash_including(id: '1')).to_return(body: 'not json')
    stub_order(2, [['A', '1']])

    refresh = StockReservationRefresher.call(:b2b)

    assert_equal 'success', refresh.status
    assert_equal ['2'], StockReservation.b2b.distinct.pluck(:tiny_order_id)
  end

  test 'skips when another run is in progress, but not when that run is stale' do
    StockReservationRefresh.for(:b2b).update!(status: 'running')
    StockReservationRefresher.call(:b2b)
    assert_not_requested :get, SEARCH_URL

    StockReservationRefresh.for(:b2b).update_columns(updated_at: 6.minutes.ago)
    stub_empty_queue('tiny2')
    assert_equal 'success', StockReservationRefresher.call(:b2b).status
  end

  test 'the job refreshes both accounts when none is given' do
    stub_empty_queue('tiny2')
    stub_empty_queue('tiny3')

    StockReservationRefreshJob.perform_now

    assert_equal %w[success success], StockReservationRefresh.order(:account).pluck(:status)
  end
end
