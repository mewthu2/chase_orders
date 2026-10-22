require 'test_helper'

class TransferLocationsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(name: 'Admin TL', email: 'admin_tl@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
  end

  test 'user without transfer_locations access is redirected' do
    profile = Profile.create!(name: 'Sem Acesso TL')
    user = User.create!(name: 'Sem Acesso TL', email: 'sem_acesso_tl@example.com', password: 'password123')
    user.profiles << profile
    sign_in user

    get transfer_locations_path
    assert_redirected_to root_path
  end

  test 'admin can list, create and update a transfer location' do
    sign_in @admin

    get transfer_locations_path
    assert_response :success

    get new_transfer_location_path
    assert_response :success

    assert_difference 'TransferLocation.count', 1 do
      post transfer_locations_path, params: { transfer_location: {
        name: 'CD Novo', registration: '25.405.327/0001-74', street: 'Rua A',
        number: '10', neighbourhood: 'Bairro', city: 'BH', state: 'MG', zip: '30000-000'
      } }
    end
    location = TransferLocation.find_by(name: 'CD Novo')
    assert_redirected_to transfer_locations_path

    patch transfer_location_path(location), params: { transfer_location: { name: 'CD Renomeado' } }
    assert_equal 'CD Renomeado', location.reload.name
  end

  test 'destroy is blocked when the location still has b2b_orders' do
    sign_in @admin
    location = TransferLocation.create!(
      name: 'CD Com Pedido', registration: '25.405.327/0001-74', street: 'Rua A',
      number: '10', neighbourhood: 'Bairro', city: 'BH', state: 'MG', zip: '30000-000'
    )
    order = B2bOrder.new(kind: :stock_transfer, transfer_location: location, user: @admin, receiver_name: 'Maria')
    order.b2b_order_items.build(sku: 'SKU1', quantity: 1, price: 1)
    order.save!

    assert_no_difference 'TransferLocation.count' do
      delete transfer_location_path(location)
    end
    assert_redirected_to transfer_locations_path
  end

  test 'the IBGE city code can be saved on a transfer location' do
    sign_in @admin
    location = TransferLocation.create!(
      name: 'CD IBGE', registration: '25.405.327/0001-74', street: 'Rua A',
      number: '10', neighbourhood: 'Bairro', city: 'BH', state: 'MG', zip: '30000-000'
    )

    get edit_transfer_location_path(location)
    assert_select 'input[name="transfer_location[city_ibge_code]"]'

    patch transfer_location_path(location), params: { transfer_location: { city_ibge_code: '3106200' } }
    assert_equal '3106200', location.reload.city_ibge_code
  end
end
