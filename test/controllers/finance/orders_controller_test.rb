require 'test_helper'
require_relative '../../support/finance_factory'

class Finance::OrdersControllerTest < ActionDispatch::IntegrationTest
  include FinanceFactory

  def setup
    @finance = finance_user('Financeiro', email: 'financeiro@chasebrasil.com')
    Finance::Setup.ensure_profile!
    @finance.reload
    @viewer = finance_user('So Ve')
    profile = Profile.create!(name: 'Só vê financeiro')
    profile.screen_actions = { 'finance_orders' => 'V' }
    profile.save!
    @viewer.profiles << profile
    @boleto = finance_order(user: @finance, price: 300, payment_terms: '30 60 90', salesperson_name: 'Ana')
    @pix = finance_order(user: @finance, price: 150, payment_method: 'pix')
  end

  test 'lista mostra pix como pago e parcelas do boleto como pendentes' do
    sign_in @finance
    get finance_orders_path(mes: 'todos')
    assert_response :success
    assert_select 'td', text: /Pago/
    assert_select 'td', text: /Pendente/
    assert_select '.row-select-checkbox[data-open=true]', count: 3
    assert_match 'cadastro pendente', response.body
  end

  test 'pay grava data e quem deu baixa; unpay desfaz' do
    sign_in @finance
    payment = @boleto.payments.first
    patch pay_finance_payment_path(payment), params: { paid_at: '2026-11-20' }
    assert_redirected_to finance_orders_path
    payment.reload
    assert_equal Date.new(2026, 11, 20), payment.paid_at
    assert_equal @finance, payment.paid_by
    patch unpay_finance_payment_path(payment)
    assert_nil payment.reload.paid_at
    assert_nil payment.paid_by
  end

  test 'pay_many baixa so as pendentes dos ids' do
    sign_in @finance
    p1, p2, p3 = @boleto.payments.to_a
    p1.update!(paid_at: Date.new(2026, 1, 1))
    patch pay_many_finance_payments_path, params: { ids: [p1.id, p2.id].join(','), paid_at: '2026-11-21' }
    assert_equal Date.new(2026, 1, 1), p1.reload.paid_at
    assert_equal Date.new(2026, 11, 21), p2.reload.paid_at
    assert_nil p3.reload.paid_at
  end

  test 'quem so ve nao da baixa' do
    sign_in @viewer
    get finance_orders_path
    assert_response :success
    patch pay_finance_payment_path(@boleto.payments.first)
    assert_redirected_to root_path
    assert_nil @boleto.payments.first.reload.paid_at
  end

  test 'parcela de pedido cancelado nao recebe baixa' do
    sign_in @finance
    @boleto.update_column(:status, B2bOrder.statuses[:cancelado])
    patch pay_finance_payment_path(@boleto.payments.first)
    assert_nil @boleto.payments.first.reload.paid_at
  end
end

class Finance::OrdersReviewFixesTest < ActionDispatch::IntegrationTest
  include FinanceFactory

  def setup
    @finance = finance_user('Financeiro', email: 'financeiro@chasebrasil.com')
    Finance::Setup.ensure_profile!
    @finance.reload
    sign_in @finance
  end

  test 'vencidas de meses anteriores aparecem no mes atual' do
    old = finance_order(user: @finance, price: 500, payment_terms: '30', created_at: 5.months.ago)
    get finance_orders_path
    assert_select '.row-select-checkbox[data-id=?]', old.payments.first.id.to_s
  end

  test 'baixa em lote pode usar a data do vencimento' do
    order = finance_order(user: @finance, price: 300, payment_terms: '30 60', created_at: Time.zone.local(2025, 1, 1))
    p1, p2 = order.payments.to_a
    patch pay_many_finance_payments_path, params: { ids: "#{p1.id},#{p2.id}", on_due: '1' }
    assert_equal [p1.due_date, p2.due_date], [p1.reload.paid_at, p2.reload.paid_at]
  end

  test 'pix que ja tinha parcela paga mostra so o restante como pago na criacao' do
    order = finance_order(user: @finance, price: 300, payment_terms: '30 60 90')
    order.payments.first.update!(paid_at: Date.current)
    order.update!(payment_method: 'pix')
    get finance_orders_path(mes: 'todos')
    assert_select '.row-select-checkbox[data-value=?]', '200.0'
    assert_select '.row-select-checkbox[data-value=?]', '100.0'
  end
end
