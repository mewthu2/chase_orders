require 'test_helper'
require_relative '../../support/finance_factory'

# No Financeiro dá para trocar ou tirar o consultor (quem recomendou) de um pedido.
class Finance::OrderConsultantEditTest < ActionDispatch::IntegrationTest
  include FinanceFactory

  def setup
    @finance = finance_user('Financeiro', email: 'financeiro@chasebrasil.com')
    Finance::Setup.ensure_profile!
    @finance.reload
    @carla = Consultant.create!(name: 'Carla Souza')
    @order = finance_order(user: @finance, salesperson_name: 'Ana', payment_method: 'pix')
    sign_in @finance
  end

  test 'abre a edicao do consultor' do
    get edit_finance_order_path(@order)
    assert_response :success
    assert_select 'select[name=consultant_id] option', text: 'Carla Souza'
  end

  test 'escolhe um consultor cadastrado' do
    patch finance_order_path(@order), params: { consultant_id: @carla.id }
    assert_redirected_to finance_orders_path
    @order.reload
    assert_equal @carla.id, @order.consultant_id
    assert_equal 'Carla Souza', @order.salesperson_name
  end

  test 'digita um nome livre' do
    patch finance_order_path(@order), params: { name: ' Bia ' }
    @order.reload
    assert_nil @order.consultant_id
    assert_equal 'Bia', @order.salesperson_name
  end

  test 'tira o consultor' do
    @order.update_columns(consultant_id: @carla.id, salesperson_name: 'Carla Souza')
    patch finance_order_path(@order), params: { remove: '1' }
    @order.reload
    assert_nil @order.consultant_id
    assert_nil @order.salesperson_name
  end

  test 'quem so ve nao edita' do
    viewer = finance_user('So Ve')
    profile = Profile.create!(name: 'Só vê fin')
    profile.screen_actions = { 'finance_orders' => 'V' }
    profile.save!
    viewer.profiles << profile
    sign_in viewer.reload
    patch finance_order_path(@order), params: { remove: '1' }
    assert_equal 'Ana', @order.reload.salesperson_name
  end
end
