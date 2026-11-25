require 'test_helper'
require_relative '../../support/finance_factory'

# Área Financeiro: só admins e o perfil Financeiro.
class Finance::AccessTest < ActionDispatch::IntegrationTest
  include FinanceFactory

  def setup
    @finance = finance_user('Financeiro', email: 'financeiro@chasebrasil.com')
    Finance::Setup.ensure_profile!
    @finance.reload
    @admin = finance_user('Admin')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @common = finance_user('Comum')
  end

  test 'usuario comum nao entra nem ve a area no menu' do
    sign_in @common
    [finance_orders_path, finance_consultants_path, finance_commissions_path].each do |path|
      get path
      assert_redirected_to root_path
    end
    assert_not Navigation.for(@common).any? { |a| a[:id] == 'financeiro' }
  end

  test 'financeiro e admin entram nas tres telas' do
    [@finance, @admin].each do |user|
      sign_in user
      [finance_orders_path, finance_consultants_path, finance_commissions_path].each do |path|
        get path
        assert_response :success, "#{user.name} #{path}"
      end
      assert Navigation.for(user).any? { |a| a[:id] == 'financeiro' }
      sign_out user
    end
  end
end
