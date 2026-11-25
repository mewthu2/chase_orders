require 'test_helper'
require_relative '../../support/finance_factory'

class Finance::CommissionsControllerTest < ActionDispatch::IntegrationTest
  include FinanceFactory

  def setup
    @finance = finance_user('Financeiro', email: 'financeiro@chasebrasil.com')
    Finance::Setup.ensure_profile!
    @finance.reload
    @typist = finance_user('Digitadora')
    @consultant = Consultant.create!(name: 'Carla')
    finance_order(user: @typist, price: 100, payment_method: 'pix', consultant: @consultant, created_at: Time.zone.local(2026, 11, 5))
    sign_in @finance
  end

  test 'index lista vendedor e consultor do mes' do
    CommissionRate.create!(beneficiary: @consultant, percent: 5)
    get finance_commissions_path(mes: '2026-11')
    assert_response :success
    assert_match 'Digitadora', response.body
    assert_match 'Carla', response.body
    assert_match 'R$ 5,00', response.body
  end

  test 'quadro de percentuais lista vendedores e consultores ativos mesmo sem venda no mes' do
    Consultant.create!(name: 'Sem Venda')
    get finance_commissions_path(mes: '2027-03')
    assert_select "input[name='percents[Consultant-#{@consultant.id}]']"
    assert_select "input[name='percents[User-#{@typist.id}]']"
    assert_match 'Sem Venda', response.body
  end

  test 'salvar percentuais grava geral e vazio apaga' do
    CommissionRate.create!(beneficiary: @consultant, percent: 5)
    post rates_finance_commissions_path, params: { mes: '2026-11', percents: { "User-#{@typist.id}" => '2,5', "Consultant-#{@consultant.id}" => '' } }
    assert_redirected_to finance_commissions_path(mes: '2026-11')
    rates = CommissionRate.percents
    assert_equal BigDecimal('2.5'), rates[['User', @typist.id]]
    assert_not rates.key?(['Consultant', @consultant.id])
  end

  test 'percentual invalido avisa' do
    post rates_finance_commissions_path, params: { mes: '2026-11', percents: { "User-#{@typist.id}" => '150' } }
    assert_match 'não foi salvo', flash[:alert].to_s
    assert_empty CommissionRate.percents
  end

  test 'detalhe da pessoa e csv' do
    get person_finance_commissions_path(key: "Consultant-#{@consultant.id}", mes: '2026-11')
    assert_response :success
    assert_match "##{B2bOrder.last.id}", response.body
    get finance_commissions_path(mes: '2026-11', format: :csv)
    assert_equal 'Papel;Nome;Percentual;Base;Comissão', response.body.lines.first.strip.delete_prefix("﻿")
  end
end
