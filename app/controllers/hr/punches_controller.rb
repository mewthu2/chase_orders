module Hr
  # Recursos Humanos › Registros de ponto: todas as marcações com a foto. O RH inclui marcação esquecida e
  # desconsidera marcação errada, sempre com justificativa; nada é apagado.
  class PunchesController < ApplicationController
    guard_screen :hr_punches, actions: { create: :edit, annul: :edit }

    def index
      @date = begin
        Date.iso8601(params[:dia].to_s)
      rescue Date::Error
        Date.current
      end
      @punches = HrTimePunch.where(work_date: @date).includes(:created_by, :annulled_by, photo_attachment: :blob, employee: :company)
                            .chronological.to_a
    end

    def create
      employee = HrEmployee.find(params[:hr_employee_id])
      back = hr_employee_path(employee, mes: params[:mes])
      at = parse_local(employee, params[:date], params[:time])
      return redirect_to(back, alert: 'Informe o dia e a hora da marcação.') unless at
      return redirect_to(back, alert: 'A marcação não pode ficar no futuro.') if at > Time.current

      punch = employee.time_punches.new(kind: params[:kind], punched_at: at, work_date: Date.iso8601(params[:date].to_s), source: 'manual',
                                        created_by: current_user, note: params[:note].to_s.strip.presence)
      HrTimePunch.transaction { punch.save! }
      HrJourneyCheckJob.perform_later(employee.id, punch.work_date.to_s)
      redirect_to back, notice: "#{punch.label} de #{punch.local_time.strftime('%d/%m %H:%M')} incluída (NSR #{punch.nsr_text})."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to back, alert: e.record.errors.full_messages.to_sentence
    end

    def annul
      punch = HrTimePunch.find(params[:id])
      back = params[:return_to].to_s.start_with?('/rh/') ? params[:return_to].to_s : hr_employee_path(punch.employee)
      reason = params[:reason].to_s.strip
      return redirect_to(back, alert: 'Conte o motivo para desconsiderar a marcação.') if reason.blank?
      return redirect_to(back, alert: 'Esta marcação já foi desconsiderada.') if punch.annulled?

      punch.annul!(current_user, reason)
      redirect_to back, notice: "#{punch.label} de #{punch.local_time.strftime('%d/%m %H:%M')} desconsiderada. Ela continua no histórico."
    end

    private

    def parse_local(employee, date, time)
      return nil unless date.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/) && time.to_s.match?(HrEmployee::TIME_FORMAT)

      employee.time_zone.parse("#{date} #{time}")
    rescue ArgumentError
      nil
    end
  end
end
