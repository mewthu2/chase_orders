require 'test_helper'
require_relative '../support/finance_factory'

class B2bOrderPaymentTest < ActiveSupport::TestCase
  include FinanceFactory

  test 'overdue so traz pendentes vencidas' do
    order = finance_order(user: finance_user, payment_terms: '30 60 90', created_at: 70.days.ago)
    p1, p2, p3 = order.payments.reload.to_a
    p1.update!(paid_at: Date.current)
    assert_equal [p2.id], B2bOrderPayment.overdue.pluck(:id)
    assert_not p3.overdue?
  end

  test 'CommissionRate.copy_previous! copia do ultimo mes com linhas e nao sobrescreve' do
    a = finance_user('Ana')
    b = Consultant.create!(name: 'Bia')
    CommissionRate.create!(month: Date.new(2026, 9, 1), beneficiary: a, percent: 1)
    CommissionRate.create!(month: Date.new(2026, 10, 1), beneficiary: a, percent: 2)
    CommissionRate.create!(month: Date.new(2026, 10, 1), beneficiary: b, percent: 5)
    CommissionRate.create!(month: Date.new(2026, 12, 1), beneficiary: b, percent: 7)

    assert_equal 1, CommissionRate.copy_previous!(Date.new(2026, 12, 15))
    rates = CommissionRate.for_month(Date.new(2026, 12, 1))
    assert_equal 2, rates[['User', a.id]]
    assert_equal 7, rates[['Consultant', b.id]]
    assert_equal 0, CommissionRate.copy_previous!(Date.new(2026, 9, 1))
  end
end
