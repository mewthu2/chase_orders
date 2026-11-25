require 'test_helper'
require_relative '../../support/finance_factory'

class Finance::CommissionsTest < ActiveSupport::TestCase
  include FinanceFactory

  NOV = Date.new(2026, 11, 1)
  DEC = Date.new(2026, 12, 1)

  def setup
    @typist = finance_user('Digitadora')
    @consultant = Consultant.create!(name: 'Carla')
  end

  def rate(who, percent, month = NOV) = CommissionRate.create!(month: month, beneficiary: who, percent: percent)
  def row(result, beneficiary) = result.rows.find { |r| r.beneficiary == beneficiary }

  test 'digitador recebe sobre o total com frete no mes do pedido' do
    rate(@typist, 2)
    finance_order(user: @typist, price: 300, freight: 30, payment_terms: '30 60', created_at: Time.zone.local(2026, 11, 5))
    finance_order(user: @typist, price: 999, created_at: Time.zone.local(2026, 10, 5))
    r = row(Finance::Commissions.new(month: NOV), @typist)
    assert_equal :typist, r.role
    assert_equal 330, r.base
    assert_equal BigDecimal('6.60'), r.commission
  end

  test 'consultor de pix recebe o total no mes do pedido' do
    rate(@consultant, 5)
    finance_order(user: @typist, price: 200, freight: 20, payment_method: 'pix', consultant: @consultant, created_at: Time.zone.local(2026, 11, 20))
    r = row(Finance::Commissions.new(month: NOV), @consultant)
    assert_equal :consultant, r.role
    assert_equal 220, r.base
    assert_equal 11, r.commission
  end

  test 'boleto 3x so conta as parcelas pagas, no mes do pagamento' do
    rate(@consultant, 10)
    rate(@consultant, 10, DEC)
    order = finance_order(user: @typist, price: 300, payment_terms: '30 60 90', consultant: @consultant, created_at: Time.zone.local(2026, 10, 1))
    p1, p2, = order.payments.reload.to_a
    p1.update!(paid_at: Date.new(2026, 11, 3))
    p2.update!(paid_at: Date.new(2026, 12, 2))
    assert_equal 100, row(Finance::Commissions.new(month: NOV), @consultant).base
    assert_equal 10, row(Finance::Commissions.new(month: NOV), @consultant).commission
    assert_equal 100, row(Finance::Commissions.new(month: DEC), @consultant).base
    assert_equal 1, row(Finance::Commissions.new(month: NOV), @consultant).entries.size
  end

  test 'pedido cancelado nao entra' do
    rate(@typist, 2)
    order = finance_order(user: @typist, price: 300, payment_method: 'pix', consultant: @consultant, created_at: Time.zone.local(2026, 11, 5))
    order.update_column(:status, B2bOrder.statuses[:cancelado])
    assert_empty Finance::Commissions.new(month: NOV).rows
  end

  test 'nome sem cadastro aparece como pendente com comissao zero' do
    finance_order(user: @typist, price: 100, payment_method: 'cartao', payment_terms: '30 60', salesperson_name: ' Ana ', created_at: Time.zone.local(2026, 11, 5))
    finance_order(user: @typist, price: 50, payment_method: 'pix', salesperson_name: 'ana', created_at: Time.zone.local(2026, 11, 6))
    r = Finance::Commissions.new(month: NOV).rows.find { |x| x.role == :consultant }
    assert r.pending
    assert_equal 'Ana', r.name
    assert_equal 'name-ana', r.key
    assert_nil r.percent
    assert_equal 150, r.base
    assert_equal 0, r.commission
  end

  test 'percentual de outro mes nao afeta o mes' do
    rate(@typist, 2)
    finance_order(user: @typist, price: 100, payment_method: 'pix', created_at: Time.zone.local(2026, 11, 5))
    rate(@typist, 9, DEC)
    result = Finance::Commissions.new(month: NOV)
    assert_equal 2, row(result, @typist).commission
    assert_equal({ base: 100, commission: 2 }, result.totals)
  end
end
