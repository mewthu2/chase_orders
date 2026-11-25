# Financeiro vale desde sempre: gera as parcelas dos boletos (e dos pedidos sem forma de pagamento) de todos os
# pedidos de atacado não cancelados que ainda não têm, e cria o perfil Financeiro para financeiro@chasebrasil.com.
# Idempotente: pode rodar a qualquer momento e mais de uma vez.
class BackfillFinance < ActiveRecord::Migration[8.1]
  def up
    [B2bOrder, B2bOrderPayment, Consultant, CommissionRate, Profile, ScreenPermission].each(&:reset_column_information)
    Finance::Setup.ensure_profile!
    say "Parcelas geradas para #{Finance::PaymentSchedule.backfill!} pedidos"
  end

  def down; end
end
