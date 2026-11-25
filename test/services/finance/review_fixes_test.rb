require 'test_helper'
require_relative '../../support/finance_factory'

# Correções da revisão final do Financeiro.
class Finance::ReviewFixesTest < ActiveSupport::TestCase
  include FinanceFactory

  def setup
    @user = finance_user
    @consultant = Consultant.create!(name: 'Carla')
    CommissionRate.create!(beneficiary: @consultant, percent: 10)
  end

  test 'boleto com parcela paga que vira pix nao conta em dobro' do
    order = finance_order(user: @user, price: 3000, payment_terms: '30 60 90', consultant: @consultant, created_at: Time.zone.local(2026, 11, 2))
    order.payments.first.update!(paid_at: Date.new(2026, 11, 10))
    order.update!(payment_method: 'pix')
    row = Finance::Commissions.new(month: Date.new(2026, 11, 1)).rows.find { |r| r.beneficiary == @consultant }
    assert_equal 3000, row.base
  end

  test 'saldo que sobra depois das parcelas pagas vira nova parcela' do
    order = finance_order(user: @user, price: 300, payment_terms: '30 60 90', created_at: Time.zone.local(2026, 11, 2))
    order.payments.first(2).each { |p| p.update!(paid_at: Date.new(2026, 11, 10)) }
    order.update!(payment_terms: '30 60')
    assert_equal 300, order.payments.reload.sum(&:amount)
    assert_equal [1, 2, 3], order.payments.map(&:number)
  end

  test 'salvar o pedido sem mudar valores mantem as mesmas parcelas' do
    order = finance_order(user: @user, price: 300, payment_terms: '30 60 90')
    ids = order.payments.reload.map(&:id)
    order.update!(tracking_code: 'AA123BR')
    assert_equal ids, order.payments.reload.map(&:id)
  end
end
