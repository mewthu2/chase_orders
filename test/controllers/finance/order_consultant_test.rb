require 'test_helper'
require 'webmock/minitest'

# Campo Consultor no pedido de atacado: escolhido da lista (vincula o cadastro) ou digitado (fica pendente).
class Finance::OrderConsultantTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(name: 'Admin Cons', email: 'admin_cons@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @client = Client.create!(responsible_name: 'Cliente Cons', registration: '25.405.327/0001-74')
    @carla = Consultant.create!(name: 'Carla Souza')
    Consultant.create!(name: 'Inativa', active: false)
    sign_in @admin
  end

  def create_with(name)
    post b2b_orders_path, params: { b2b_order: {
      kind: 'sale', payment_method: 'pix', client_id: @client.id, salesperson_name: name,
      b2b_order_items_attributes: [{ sku: 'SKU1', name: 'Produto', quantity: 1, price: 10 }]
    } }
    B2bOrder.last
  end

  test 'nome igual a um consultor cadastrado vincula o cadastro' do
    order = create_with(' carla souza ')
    assert_equal @carla.id, order.consultant_id
    assert_equal 'Carla Souza', order.salesperson_name
  end

  test 'nome livre fica so como nome, pendente' do
    order = create_with('Ana')
    assert_nil order.consultant_id
    assert_equal 'Ana', order.salesperson_name
    assert order.consultant_pending?
  end

  test 'trocar o nome desfaz o vinculo antigo' do
    order = create_with('Carla Souza')
    patch b2b_order_path(order), params: { b2b_order: { salesperson_name: 'Bia' } }
    assert_nil order.reload.consultant_id
    assert_equal 'Bia', order.salesperson_name
  end

  test 'formulario oferece os consultores ativos' do
    get new_b2b_order_path
    assert_select 'label', text: 'Consultor'
    assert_select 'datalist#consultantOptions option[value=?]', 'Carla Souza'
    assert_select 'datalist#consultantOptions option[value=?]', 'Inativa', count: 0
  end
end
