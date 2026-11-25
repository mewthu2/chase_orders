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
    [wholesale_fiscal_notes_path, finance_consultants_path, finance_commissions_path].each do |path|
      get path
      assert_redirected_to root_path
    end
    assert_not Navigation.for(@common).any? { |a| a[:id] == 'financeiro' }
  end

  test 'financeiro e admin entram nas tres telas' do
    [@finance, @admin].each do |user|
      sign_in user
      [wholesale_fiscal_notes_path, finance_consultants_path, finance_commissions_path].each do |path|
        get path
        assert_response :success, "#{user.name} #{path}"
      end
      assert Navigation.for(user).any? { |a| a[:id] == 'financeiro' }
      sign_out user
    end
  end

  # Bloqueio no servidor, não só no menu: pelo link, quem só tem o perfil Financeiro não entra em nenhuma outra tela.
  test 'so com o perfil financeiro nenhuma outra tela abre pelo link' do
    opened = []
    Rails.application.routes.routes.each do |route|
      next unless route.verb.include?('GET')

      path = route.path.spec.to_s.sub('(.:format)', '')
      next if path.include?(':') || path.include?('*') || path.start_with?('/rails', '/user', '/cable', '/assets', '/api', '/webhooks')
      next if path.match?(/sign_out|logout|impersonat|historical_location/)

      sign_in @finance
      begin
        get path
      rescue StandardError
        next
      end
      opened << path if response.status == 200
    end
    allowed = ['/', '/chamados', '/tickets/new', '/financeiro/notas_fiscais', '/financeiro/notas_fiscais/planilha', '/financeiro/comissoes', '/financeiro/consultores', '/financeiro/consultores/new']
    assert_equal [], opened - allowed
  end
end
