require 'test_helper'
require_relative '../../support/finance_factory'

class Finance::PaymentScheduleTest < ActiveSupport::TestCase
  include FinanceFactory

  def setup
    @user = finance_user
    @day = Date.new(2026, 11, 10)
  end

  test 'boleto 30 60 90 gera tres parcelas que somam o total com frete' do
    order = finance_order(user: @user, price: 300, freight: 33.33, payment_terms: '30 60 90', created_at: @day)
    payments = order.payments.reload
    assert_equal [111.11, 111.11, 111.11], payments.map { |p| p.amount.to_f }
    assert_equal [@day + 30, @day + 60, @day + 90], payments.map(&:due_date)
    assert_equal order.grand_total, payments.sum(&:amount)
  end

  test 'sem forma de pagamento gera uma parcela vencendo na data do pedido' do
    order = finance_order(user: @user, price: 200, payment_method: nil, created_at: @day)
    assert_equal [[1, @day, 200]], order.payments.reload.map { |p| [p.number, p.due_date, p.amount.to_i] }
  end

  test 'pix nao gera parcela' do
    order = finance_order(user: @user, payment_method: 'pix')
    assert_empty order.payments.reload
  end

  test 'editar valor refaz so as pendentes sobre o saldo' do
    order = finance_order(user: @user, price: 300, payment_terms: '30 60 90', created_at: @day)
    first = order.payments.reload.first
    first.update!(paid_at: Date.current)
    order.update_column(:freight_value, 120) # total 420
    Finance::PaymentSchedule.call(order)
    payments = order.payments.reload
    assert_equal [[1, 100], [2, 160], [3, 160]], payments.map { |p| [p.number, p.amount.to_i] }
    assert payments.first.paid?
  end

  test 'trocar boleto por pix apaga pendentes e mantem pagas' do
    order = finance_order(user: @user, price: 300, payment_terms: '30 60 90', created_at: @day)
    order.payments.reload.first.update!(paid_at: Date.current)
    order.update!(payment_method: 'pix')
    assert_equal [1], order.payments.reload.map(&:number)
  end

  test 'pedido cancelado nao mexe nas parcelas' do
    order = finance_order(user: @user, price: 300, payment_terms: '30 60', created_at: @day)
    order.update_column(:freight_value, 100)
    order.update_column(:status, B2bOrder.statuses[:cancelado])
    Finance::PaymentSchedule.call(order.reload)
    assert_equal [150, 150], order.payments.reload.map { |p| p.amount.to_i }
  end
end
