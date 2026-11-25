require 'test_helper'
require_relative '../../support/finance_factory'

class Finance::ConsultantsControllerTest < ActionDispatch::IntegrationTest
  include FinanceFactory

  def setup
    @finance = finance_user('Financeiro', email: 'financeiro@chasebrasil.com')
    Finance::Setup.ensure_profile!
    @finance.reload
    sign_in @finance
  end

  test 'cria edita e exclui consultor' do
    post finance_consultants_path, params: { consultant: { name: 'Carla Souza', phone: '31 9999', pix_key: 'carla@pix' } }
    consultant = Consultant.last
    assert_equal 'Carla Souza', consultant.name
    patch finance_consultant_path(consultant), params: { consultant: { active: '0' } }
    assert_not consultant.reload.active
    delete finance_consultant_path(consultant)
    assert_not Consultant.exists?(consultant.id)
  end

  test 'lista os nomes pendentes e vincula todos os pedidos daquele nome' do
    a = finance_order(user: @finance, salesperson_name: 'Ana ')
    b = finance_order(user: @finance, salesperson_name: 'ana')
    other = finance_order(user: @finance, salesperson_name: 'Bia')
    get finance_consultants_path
    assert_match 'Ana', response.body
    post link_name_finance_consultants_path, params: { name: 'ana', create: '1' }
    consultant = Consultant.find_by(name: 'Ana')
    assert consultant
    assert_equal [consultant.id, consultant.id], [a.reload.consultant_id, b.reload.consultant_id]
    assert_equal 'Ana', b.salesperson_name
    assert_nil other.reload.consultant_id
  end

  test 'vincula nome a consultor existente' do
    carla = Consultant.create!(name: 'Carla Souza')
    order = finance_order(user: @finance, salesperson_name: 'Carla')
    post link_name_finance_consultants_path, params: { name: 'Carla', consultant_id: carla.id }
    assert_equal carla.id, order.reload.consultant_id
    assert_equal 'Carla Souza', order.salesperson_name
  end
end
