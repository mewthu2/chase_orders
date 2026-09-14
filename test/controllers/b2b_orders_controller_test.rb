require 'test_helper'

class B2bOrdersControllerTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(name: 'Admin B2B', email: 'admin_b2b@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @client = Client.create!(responsible_name: 'Cliente B2B Test', registration: '25.405.327/0001-74')
  end

  test 'user without b2b_orders access is redirected' do
    profile = Profile.create!(name: 'Sem Acesso B2B')
    user = User.create!(name: 'Sem Acesso B2B', email: 'sem_acesso_b2b@example.com', password: 'password123')
    user.profiles << profile
    sign_in user

    get b2b_orders_path
    assert_redirected_to root_path
  end

  test 'admin can create a draft without items or client' do
    sign_in @admin

    assert_difference 'B2bOrder.count', 1 do
      post b2b_orders_path, params: { b2b_order: { kind: 'sale', status: 'draft' } }
    end
    assert_redirected_to b2b_orders_path
  end

  test 'admin can create a saved sale order with client and items' do
    sign_in @admin

    assert_difference 'B2bOrder.count', 1 do
      post b2b_orders_path, params: { b2b_order: {
        kind: 'sale', status: 'saved', client_id: @client.id,
        b2b_order_items_attributes: [{ sku: 'SKU1', name: 'Produto', quantity: 2, price: 10 }]
      } }
    end
    order = B2bOrder.last
    assert order.saved?
    assert_equal 1, order.b2b_order_items.count
  end

  test 'saving without items when not draft re-renders with errors' do
    sign_in @admin

    assert_no_difference 'B2bOrder.count' do
      post b2b_orders_path, params: { b2b_order: { kind: 'sale', status: 'saved', client_id: @client.id } }
    end
    assert_response :unprocessable_entity
  end

  test 'transmit enqueues the job only when transmittable' do
    sign_in @admin
    order = B2bOrder.create!(kind: :sale, status: :draft, user: @admin, client: @client)

    assert_no_enqueued_jobs only: TransmitB2bOrderJob do
      post transmit_b2b_order_path(order)
    end
    assert_redirected_to b2b_orders_path

    order.update!(status: :saved)
    order.b2b_order_items.create!(sku: 'SKU1', quantity: 1, price: 1)

    assert_enqueued_with(job: TransmitB2bOrderJob, args: [order.id]) do
      post transmit_b2b_order_path(order)
    end
  end
end
