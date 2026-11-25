# Ponto pelo link do funcionário (sem login): a página abre a câmera, a pessoa escolhe a marcação
# (entrada, saída e volta do intervalo, saída), tira a foto e o horário gravado é o do servidor, no fuso do
# estado onde ela trabalha. Depois de cada marcação a jornada é conferida (HrJourneyCheckJob).
class PunchClockController < ApplicationController
  skip_before_action :authenticate_user!
  skip_before_action :preload_current_user
  layout false
  before_action :set_employee

  MIN_GAP = 60.seconds

  rate_limit to: 12, within: 1.minute, only: :create, with: -> { render json: { ok: false, error: 'Muitas tentativas seguidas. Espere um minuto.' }, status: :too_many_requests }

  def show
    @today_punches = today_punches
    @suggested = @employee.suggested_kind(@today_punches)
  end

  def create
    kind = params[:kind].to_s
    return fail_with('Escolha a marcação: entrada, intervalo ou saída.') unless HrTimePunch::KINDS.key?(kind)

    last = @employee.valid_punches.order(punched_at: :desc).first
    return fail_with("Você acabou de bater o ponto (#{last.local_time.strftime('%H:%M')}). Espere um minuto.") if last && last.punched_at > MIN_GAP.ago

    now = Time.current
    punch = @employee.time_punches.new(kind: kind, punched_at: now, work_date: @employee.work_date_for(kind, now), source: 'link',
                                       ip: request.remote_ip, user_agent: request.user_agent.to_s.first(255))
    punch.photo_data_url = params[:photo]
    save_with_nsr!(punch)
    HrJourneyCheckJob.perform_later(@employee.id, punch.work_date.to_s)

    local = punch.local_time
    render json: { ok: true, punch: { label: punch.label, emoji: HrTimePunch::KINDS.dig(kind, :emoji), time: local.strftime('%H:%M'),
                                      date: I18n.l(local.to_date, format: '%A, %d/%m/%Y'), nsr: punch.nsr_text } }
  rescue ActiveRecord::RecordInvalid => e
    fail_with(e.record.errors.full_messages.to_sentence)
  end

  private

  def set_employee
    @employee = HrEmployee.active.includes(:company).find_by(punch_token: params[:token].to_s)
    return if @employee

    request.format.json? || request.post? ? render(json: { ok: false, error: 'Link inválido ou desativado. Fale com o RH.' }, status: :not_found) : render(:unavailable, status: :not_found)
  end

  def today_punches
    @employee.valid_punches.where(work_date: [@employee.today - 1, @employee.today]).chronological.to_a
             .select { |p| p.work_date == @employee.today || p.punched_at > 16.hours.ago }
  end

  # NSR é sequencial e único: se outra marcação pegou o mesmo número ao mesmo tempo, tenta de novo.
  def save_with_nsr!(punch, tries = 3)
    HrTimePunch.transaction { punch.save! }
  rescue ActiveRecord::RecordNotUnique
    raise if (tries -= 1).zero?

    punch.nsr = nil
    retry
  end

  def fail_with(message, status = :unprocessable_content)
    render json: { ok: false, error: message }, status: status
  end
end
