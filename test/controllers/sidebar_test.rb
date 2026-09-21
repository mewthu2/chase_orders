require 'test_helper'

class SidebarTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(name: 'Admin Menu', email: 'admin_menu@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
  end

  test 'the orders group is called Pedidos B2B and links to companies and fiscal notes' do
    sign_in @admin
    get b2b_orders_path

    assert_select '.nav-group-title .nav-text', text: 'Pedidos B2B'
    assert_select "a[href='#{companies_path}']", text: /Empresas/
    assert_select "a[href='#{fiscal_notes_path}']", text: /Notas Fiscais/
  end

  test 'a user without the new permissions does not see the links' do
    profile = Profile.create!(name: 'So Atacado')
    profile.update!(screen_keys: ['b2b_orders'])
    user = User.create!(name: 'Sem Fiscal', email: 'sem_fiscal@example.com', password: 'password123')
    user.profiles << profile
    sign_in user
    get b2b_orders_path

    assert_select "a[href='#{companies_path}']", count: 0
    assert_select "a[href='#{fiscal_notes_path}']", count: 0
  end

  test 'the Produtos group links to stock withdrawals only for users with that permission' do
    sign_in @admin
    get b2b_orders_path
    assert_select "a[href='#{stock_withdrawals_path}']", text: /Retirada de Estoque/

    profile = Profile.create!(name: 'So Controle')
    profile.update!(screen_keys: ['stock_corrections'])
    user = User.create!(name: 'So Controle', email: 'so_controle@example.com', password: 'password123')
    user.profiles << profile
    sign_in user
    get stock_corrections_path
    assert_select "a[href='#{stock_corrections_path}']"
    assert_select "a[href='#{stock_withdrawals_path}']", count: 0

    only_withdrawals = Profile.create!(name: 'So Retirada')
    only_withdrawals.update!(screen_keys: ['stock_withdrawals'])
    user2 = User.create!(name: 'So Retirada', email: 'so_retirada@example.com', password: 'password123')
    user2.profiles << only_withdrawals
    sign_in user2
    get stock_withdrawals_path
    assert_response :success
    assert_select "a[href='#{stock_withdrawals_path}']"
    assert_select "a[href='#{stock_corrections_path}']", count: 0
  end
end
