require 'test_helper'
require 'webmock/minitest'

class CarriersControllerTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(name: 'Admin Carrier', email: 'admin_carrier@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
  end

  test 'user without carriers access is redirected' do
    profile = Profile.create!(name: 'Sem Acesso Carrier')
    user = User.create!(name: 'Sem Acesso Carrier', email: 'sem_acesso_carrier@example.com', password: 'password123')
    user.profiles << profile
    sign_in user

    get carriers_path
    assert_redirected_to root_path
  end

  test 'admin can list, create and update a carrier' do
    sign_in @admin

    get carriers_path
    assert_response :success

    get new_carrier_path
    assert_response :success

    assert_difference 'Carrier.count', 1 do
      post carriers_path, params: { carrier: {
        name: 'Jamef', registration: '25.405.327/0001-74', street: 'Rua A',
        number: '10', neighbourhood: 'Bairro', city: 'BH', state: 'MG', zip: '30000-000'
      } }
    end
    carrier = Carrier.find_by(name: 'Jamef')
    assert_redirected_to carriers_path

    patch carrier_path(carrier), params: { carrier: { name: 'Jamef Renomeada' } }
    assert_equal 'Jamef Renomeada', carrier.reload.name
  end

  test 'destroy is blocked when the carrier still has b2b_orders' do
    sign_in @admin
    carrier = Carrier.create!(
      name: 'Com Pedido', registration: '25.405.327/0001-74', street: 'Rua A',
      number: '10', neighbourhood: 'Bairro', city: 'BH', state: 'MG', zip: '30000-000'
    )
    B2bOrder.create!(kind: :sale, status: :draft, carrier: carrier, user: @admin)

    assert_no_difference 'Carrier.count' do
      delete carrier_path(carrier)
    end
    assert_redirected_to carriers_path
  end

  test 'transmit updates the carrier on success' do
    ENV['TOKEN_TINY2_PRODUCTION'] = 'fake-token'
    sign_in @admin
    carrier = Carrier.create!(
      name: 'Transmitir', registration: '25.405.327/0001-74', street: 'Rua A',
      number: '10', neighbourhood: 'Bairro', city: 'BH', state: 'MG', zip: '30000-000'
    )

    stub_request(:post, 'https://api.tiny.com.br/api2/contato.incluir.php')
      .to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '999' } } } }.to_json)

    post transmit_carrier_path(carrier)

    assert_redirected_to carriers_path
    carrier.reload
    assert_equal '999', carrier.tiny_contact_id
    assert carrier.transmitted?
  end

  test 'transmit records the error on failure' do
    ENV['TOKEN_TINY2_PRODUCTION'] = 'fake-token'
    sign_in @admin
    carrier = Carrier.create!(
      name: 'Falha', registration: '25.405.327/0001-74', street: 'Rua A',
      number: '10', neighbourhood: 'Bairro', city: 'BH', state: 'MG', zip: '30000-000'
    )

    stub_request(:post, 'https://api.tiny.com.br/api2/contato.incluir.php')
      .to_return(body: { retorno: { status: 'Erro', erros: { erro: 'CNPJ inválido' } } }.to_json)

    post transmit_carrier_path(carrier)

    assert_redirected_to carriers_path
    carrier.reload
    assert_equal 'CNPJ inválido', carrier.tiny_error
    refute carrier.transmitted?
  end
end
