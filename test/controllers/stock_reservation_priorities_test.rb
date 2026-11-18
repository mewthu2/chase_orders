require 'test_helper'
require 'webmock/minitest'
require 'minitest/mock'

# Adm › Logística › Priorização de reserva de estoque: a escadinha decide quais reservas cada origem respeita.
class StockReservationPrioritiesTest < ActionDispatch::IntegrationTest
  def setup
    ENV['CORREIOS_ESTOQUE'] = 'https://correios-log.example.com/estoque/'
    ENV['CORREIOS_CARTAO_POSTAGEM'] = 'cartao-b2c'
    ENV['CORREIOS_CARTAO_POSTAGEM_2'] = 'cartao-b2b'
    ENV['TOKEN_LOG_PRODUCTION'] = 'token-b2c'
    ENV['TOKEN_LOG_PRODUCTION2'] = 'token-b2b'
    @admin = User.create!(name: 'Admin', email: 'admin_srp@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    Product.create!(sku: 'SKU1', shopify_product_name: 'Legging')
    stub_request(:get, 'https://correios-log.example.com/estoque/SKU1/estoque').to_return(status: 200, body: { disponivel: 10 }.to_json)
    sign_in @admin
  end

  def reserve(account, source, quantity, key = source)
    StockReservation.create!(account:, source:, tiny_order_id: key, sku: 'SKU1', quantity:)
  end

  def available(source)
    B2bStockAvailability.for_sku('SKU1', source:).available
  end

  def transfer_params(quantity)
    { b2b_order: { transfer_direction: 'b2c_to_b2b', b2b_order_items_attributes: [{ sku: 'SKU1', name: 'Legging', quantity:, price: 10 }] } }
  end

  test 'the Adm menu has Logística with the screen, showing both stocks and every source' do
    get stock_reservation_priority_path

    assert_response :success
    assert_select ".sb-section[data-area='adm'] a[href='#{stock_reservation_priority_path}']", text: /Priorização de reserva de estoque/
    StockReservationPriority::SOURCES.each_key { |source| assert_select "select[name='levels[#{source}]']" }
    assert_select '.srp-ladder', count: 2
  end

  test 'by default a B2C order ignores the B2C to B2B transfer, and the transfer respects the B2C orders' do
    reserve(:b2c, 'b2c_orders', 3)
    reserve(:b2c, 'b2c_to_b2b', 4)

    assert_equal 3, available('b2c_to_b2b')
    assert_equal 7, available('b2c_orders')
    assert_equal %w[b2c_orders], StockReservationPriority.counted_sources('b2c_orders')
    assert_empty StockReservationPriority.ahead_of('b2c_orders')
  end

  test 'by default the Log02 sources keep counting against each other' do
    reserve(:b2b, 'sale', 2)
    reserve(:b2b, 'stock_transfer', 3)
    reserve(:b2b, 'b2c_transfer', 1)

    assert_equal 4, available('sale')
    assert_equal 4, available('b2c_transfer')
  end

  test 'saving the ladder changes who is ignored' do
    reserve(:b2b, 'sale', 2)
    reserve(:b2b, 'stock_transfer', 3)

    patch stock_reservation_priority_path, params: { levels: { sale: 1, stock_transfer: 2, b2c_transfer: 3 } }

    assert_redirected_to stock_reservation_priority_path
    assert_equal 8, available('sale')
    assert_equal 5, available('stock_transfer')
  end

  test 'an impossible step is refused' do
    patch stock_reservation_priority_path, params: { levels: { b2c_orders: 9 } }

    assert_match(/entre 1 e 2/, flash[:alert])
    assert_equal 1, StockReservationPriority.levels['b2c_orders']
  end

  test 'seeing needs the view permission and saving needs the edit one' do
    user = User.create!(name: 'Sem acesso', email: 'sem_srp@example.com', password: 'password123')
    sign_in user

    get stock_reservation_priority_path
    assert_not_equal 200, response.status
    patch stock_reservation_priority_path, params: { levels: { b2c_orders: 2 } }
    assert_equal 0, StockReservationPriority.count
  end

  test 'a B2C to B2B transfer cannot exceed the B2C stock minus the reservations it respects' do
    reserve(:b2c, 'b2c_orders', 8)

    assert_no_difference('B2bOrder.count') { post b2c_transfers_path, params: transfer_params(3) }
    assert_response :unprocessable_entity

    assert_difference('B2bOrder.count', 1) { post b2c_transfers_path, params: transfer_params(2) }
  end

  test 'the transfer reservation ends with the two production notes and comes back if one is cancelled' do
    post b2c_transfers_path, params: transfer_params(2)
    order = B2bOrder.last
    company = Company.new(legal_name: 'E', cnpj: '11.222.333/0001-81', street: 'R', number: '1', neighbourhood: 'B', city: 'BH',
                          city_ibge_code: '3106200', state: 'MG', zip: '30000000')
    company.save!(validate: false)
    main = FiscalNote.create!(company:, b2b_order: order, number: 1, series: 1, environment: :producao, status: :assinada)
    remessa = FiscalNote.create!(company:, b2b_order: order, number: 2, series: 1, environment: :producao, status: :assinada, role: 'remessa')

    main.update!(status: :autorizada)
    assert StockReservation.exists?(tiny_order_id: order.reservation_key)
    remessa.update!(status: :autorizada)
    assert_not StockReservation.exists?(tiny_order_id: order.reservation_key)

    main.update!(status: :cancelada)
    assert StockReservation.b2c.exists?(tiny_order_id: order.reservation_key)
  end

  test 'the Shopify stock only discounts what is ahead of the B2C orders' do
    reserve(:b2c, 'b2c_to_b2b', 4)
    job = UpdateShopifyStockFromCorreiosBatchJob.new
    assert_equal 0, job.send(:reserved_ahead_of_b2c_orders, 'SKU1')

    StockReservationPriority.save_levels!('b2c_to_b2b' => 1, 'b2c_orders' => 2)
    assert_equal 4, UpdateShopifyStockFromCorreiosBatchJob.new.send(:reserved_ahead_of_b2c_orders, 'SKU1')
  end
end
