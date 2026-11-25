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

  test 'percentual de comissao e um so por pessoa' do
    a = finance_user('Ana')
    CommissionRate.create!(beneficiary: a, percent: 2)
    assert_not CommissionRate.new(beneficiary: a, percent: 3).valid?
    assert_equal({ ['User', a.id] => 2 }, CommissionRate.percents)
  end
end
