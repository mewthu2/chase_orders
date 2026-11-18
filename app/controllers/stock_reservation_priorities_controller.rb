# Adm › Logística › Priorização de reserva de estoque: o degrau de cada origem de reserva.
class StockReservationPrioritiesController < ApplicationController
  guard_screen :stock_reservation_priority, actions: { show: :view, update: :edit }

  def show
    @levels = StockReservationPriority.levels
  end

  def update
    StockReservationPriority.save_levels!(params.fetch(:levels, {}).permit(*StockReservationPriority::SOURCES.keys))
    HoneyB2bLog.sync_reservations!
    redirect_to stock_reservation_priority_path, notice: 'Prioridades salvas. Já valem para as próximas consultas de estoque.'
  rescue ActiveRecord::RecordInvalid => e
    redirect_to stock_reservation_priority_path, alert: e.record.errors.full_messages.to_sentence
  end
end
