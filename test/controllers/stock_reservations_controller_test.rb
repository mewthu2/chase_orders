require 'test_helper'

class StockReservationsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  def setup
    @admin = User.create!(name: 'Admin Reservas', email: 'admin_reservas@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    Product.create!(sku: 'LEG-A', shopify_product_name: 'Legging A')
    StockReservation.create!(account: :b2b, tiny_order_id: '1', tiny_order_number: '1001', customer_name: 'Loja X', sku: 'LEG-A', quantity: 2)
    StockReservation.create!(account: :b2b, tiny_order_id: '2', tiny_order_number: '1002', customer_name: 'Loja Y', sku: 'LEG-A', quantity: 2)
    StockReservation.create!(account: :b2b, tiny_order_id: '2', tiny_order_number: '1002', customer_name: 'Loja Y', sku: 'TOP-B', quantity: 1)
    StockReservation.create!(account: :b2c, tiny_order_id: '9', tiny_order_number: '9009', customer_name: 'Cliente Z', sku: 'LEG-A', quantity: 7)
  end

  test 'b2b screen groups reservations by sku with totals and orders' do
    sign_in @admin
    get b2b_stock_reservations_path

    assert_response :success
    assert_select '.reservation-kpi', text: /2\s*pedidos/
    assert_select '.reservation-kpi', text: /2\s*SKUs/
    assert_select '.reservation-kpi', text: /5\s*unidades/
    assert_select '.reservation-sku', count: 2
    assert_select '.reservation-sku', text: /LEG-A.*Legging A/m
    assert_select '.reservation-order', text: /1001.*Loja X/m
    assert_no_match(/9009/, response.body)
  end

  test 'b2c screen shows only b2c reservations' do
    sign_in @admin
    get b2c_stock_reservations_path

    assert_match(/9009/, response.body)
    assert_no_match(/1001/, response.body)
  end

  test 'each order shows the shop order and the invoice' do
    StockReservation.create!(account: :b2c, tiny_order_id: '77', tiny_order_number: '7077', customer_name: 'Cliente NF', sku: 'LEG-A', quantity: 1, ecommerce_number: '#5501', invoice_id: '880011')
    Attempt.create!(kinds: :create_correios_order, status: :fail, tiny_order_id: 9, id_nota_fiscal: 990_022)
    sign_in @admin

    get b2c_stock_reservations_path

    assert_select '.reservation-order', text: /7077.*#5501.*880011/m
    assert_select '.reservation-order', text: /9009.*990022/m
  end

  test 'an order that already has a Correios order number is not shown, even before the next refresh' do
    StockReservation.create!(account: :b2c, tiny_order_id: '78', tiny_order_number: '7078', customer_name: 'Ja no WMS', sku: 'LEG-A', quantity: 3)
    Attempt.insert_all([{ kinds: Attempt.kinds[:create_correios_order], status: Attempt.statuses[:fail], tiny_order_id: 78,
                          order_correios_id: 25_135_290, created_at: Time.current, updated_at: Time.current }])
    sign_in @admin

    get b2c_stock_reservations_path

    assert_no_match(/7078/, response.body)
    assert_select '.reservation-kpi', text: /1\s*pedidos/
    assert_select '.reservation-kpi', text: /7\s*unidades/
  end

  test 'sku filter narrows the list' do
    sign_in @admin
    get b2b_stock_reservations_path(sku: 'top')

    assert_select '.reservation-sku', count: 1
    assert_select '.reservation-sku', text: /TOP-B/
  end

  test 'refresh enqueues the job for the account' do
    sign_in @admin

    assert_enqueued_with(job: StockReservationRefreshJob, args: ['b2c']) do
      post refresh_stock_reservations_path(account: 'b2c')
    end
    assert_redirected_to b2c_stock_reservations_path
  end

  test 'refresh rejects an unknown account' do
    sign_in @admin
    post refresh_stock_reservations_path(account: 'xyz')
    assert_response :not_found
  end

  test 'each screen needs its own permission' do
    profile = Profile.create!(name: 'So Reserva B2B')
    profile.update!(screen_keys: ['stock_reservations_b2b'])
    user = User.create!(name: 'Reserva B2B', email: 'reserva_b2b@example.com', password: 'password123')
    user.profiles << profile
    sign_in user

    get b2b_stock_reservations_path
    assert_response :success

    get b2c_stock_reservations_path
    assert_redirected_to root_path

    post refresh_stock_reservations_path(account: 'b2c')
    assert_redirected_to root_path
  end

  test 'sidebar shows the reservation link to a user with only that permission' do
    profile = Profile.create!(name: 'So Reserva B2C')
    profile.update!(screen_keys: ['stock_reservations_b2c'])
    user = User.create!(name: 'Reserva B2C', email: 'reserva_b2c@example.com', password: 'password123')
    user.profiles << profile
    sign_in user

    get b2c_stock_reservations_path

    assert_select "a[href='#{b2c_stock_reservations_path}']"
    assert_select "a[href='#{b2b_stock_reservations_path}']", count: 0
    assert_select "a[href='#{order_correios_create_dashboard_index_path}']", count: 0
  end
end
