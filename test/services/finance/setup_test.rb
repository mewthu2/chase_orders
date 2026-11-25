require 'test_helper'
require_relative '../../support/finance_factory'

class Finance::SetupTest < ActiveSupport::TestCase
  include FinanceFactory

  test 'backfill cria parcelas so de boletos sem parcelas e nao duplica' do
    user = finance_user
    boleto = finance_order(user: user, payment_terms: '30 60')
    sem_forma = finance_order(user: user, payment_method: nil)
    pix = finance_order(user: user, payment_method: 'pix')
    cancelado = finance_order(user: user, payment_terms: '30')
    B2bOrderPayment.delete_all
    cancelado.update_column(:status, B2bOrder.statuses[:cancelado])

    assert_equal 3, Finance::PaymentSchedule.backfill! # pix entra mas não gera parcela
    assert_equal 2, boleto.payments.count
    assert_equal 1, sem_forma.payments.count
    assert_equal 0, pix.payments.count
    assert_equal 0, cancelado.payments.count
    Finance::PaymentSchedule.backfill!
    assert_equal 3, B2bOrderPayment.count
  end

  test 'perfil Financeiro libera as telas da area e liga o usuario do financeiro' do
    user = finance_user('Financeiro', email: 'financeiro@chasebrasil.com')
    2.times { Finance::Setup.ensure_profile! }
    assert_equal 1, Profile.where(name: 'Financeiro').count
    user.reload
    assert user.can?(:finance_orders, 'E')
    assert user.can?(:commissions, 'P')
    assert_not user.can?(:b2b_orders, 'V')
  end
end
