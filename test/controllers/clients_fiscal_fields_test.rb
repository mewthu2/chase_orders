require 'test_helper'

class ClientsFiscalFieldsTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(name: 'Admin Clientes', email: 'admin_clients_fiscal@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    sign_in @admin
  end

  test 'the new client form has the fiscal fields' do
    get new_client_path

    assert_select 'input[name="client[city_ibge_code]"]'
    assert_select 'select[name="client[ie_indicator]"] option', count: 3
  end

  test 'creates a client with IBGE code and IE indicator' do
    assert_difference 'Client.count', 1 do
      post clients_path, params: { client: {
        responsible_name: 'Cliente Fiscal', registration: '25.405.327/0001-74',
        city_ibge_code: '3106200', ie_indicator: 1, state_registration: '123'
      } }
    end

    client = Client.last
    assert_equal '3106200', client.city_ibge_code
    assert_equal 1, client.ie_indicator
  end
end
