# Ponto pelo link do funcionário, logado no Honey com o usuário ligado a ele no RH: a página abre a câmera, a pessoa escolhe a marcação
# (entrada, saída e volta do intervalo, saída), tira a foto e o horário gravado é o do servidor, no fuso do
# estado onde ela trabalha. Depois de cada marcação a jornada é conferida (HrJourneyCheckJob).
class PunchClockController < ApplicationController
  # Login próprio: no HTML volta ao link depois de entrar; no JSON (envio da foto) responde com a mensagem em português.
  skip_before_action :authenticate_user!
  skip_before_action :preload_current_user
  layout false
  before_action :require_login
  before_action :set_employee
  before_action :require_own_link

  MIN_GAP = 60.seconds

  rate_limit to: 12, within: 1.minute, only: :create, with: -> { render json: { ok: false, error: 'Muitas tentativas seguidas. Espere um minuto.' }, status: :too_many_requests }

  def show
    @today_punches = today_punches
    @done = done_kinds
    @suggested = @employee.suggested_kind(@today_punches)
    @suggested = HrTimePunch::KINDS.keys.find { |k| !@done.key?(k) } if @done.key?(@suggested)
  end

  def create
    kind = params[:kind].to_s
    return fail_with('Escolha a marcação: entrada, intervalo ou saída.') unless HrTimePunch::KINDS.key?(kind)

    last = @employee.valid_punches.order(punched_at: :desc).first
    return fail_with("Você acabou de bater o ponto (#{last.local_time.strftime('%H:%M')}). Espere um minuto.") if last && last.punched_at > MIN_GAP.ago

    now = Time.current
    work_date = @employee.work_date_for(kind, now)
    # Uma foto por marcação no dia: a segunda Entrada (ou Saída...) do mesmo dia é recusada; correção é com o RH.
    if (same = @employee.valid_punches.find_by(kind: kind, work_date: work_date))
      return fail_with("Você já bateu #{same.label} hoje às #{same.local_time.strftime('%H:%M')}. Se precisar corrigir, fale com o RH.")
    end

    punch = @employee.time_punches.new(kind: kind, punched_at: now, work_date: work_date, source: 'link',
                                       ip: request.remote_ip, user_agent: request.user_agent.to_s.first(255))
    punch.photo_data_url = params[:photo]
    save_with_nsr!(punch)
    HrJourneyCheckJob.perform_later(@employee.id, punch.work_date.to_s)

    local = punch.local_time
    render json: { ok: true, punch: { kind: kind, label: punch.label, emoji: HrTimePunch::KINDS.dig(kind, :emoji), time: local.strftime('%H:%M'),
                                      date: I18n.l(local.to_date, format: '%A, %d/%m/%Y'), nsr: punch.nsr_text } }
  rescue ActiveRecord::RecordInvalid => e
    fail_with(e.record.errors.full_messages.to_sentence)
  end

  private

  def require_login
    return if user_signed_in?
    return fail_with('Sua sessão no Honey acabou. Recarregue a página e entre de novo.', :unauthorized) if request.post? || request.format.json?

    store_location_for(:user, request.fullpath)
    redirect_to new_user_session_path, alert: 'Entre no Honey para bater o ponto.'
  end

  # O link é do funcionário: só abre logado com o usuário ligado a ele no cadastro do RH.
  def require_own_link
    return if @employee.user_id == current_user.id

    message = @employee.user_id ? 'Este link de ponto é de outra pessoa.' : 'Este cadastro ainda não está ligado a um usuário do Honey. Fale com o RH.'
    return fail_with(message, :forbidden) if request.post? || request.format.json?

    @reason = message
    render :unavailable, status: :forbidden
  end

  def set_employee
    @employee = HrEmployee.active.includes(:company).find_by(punch_token: params[:token].to_s)
    return if @employee

    request.format.json? || request.post? ? render(json: { ok: false, error: 'Link inválido ou desativado. Fale com o RH.' }, status: :not_found) : render(:unavailable, status: :not_found)
  end

  # Marcações já feitas no dia de trabalho de cada uma: { 'entrada' => '08:02', ... }.
  def done_kinds
    now = Time.current
    HrTimePunch::KINDS.keys.filter_map do |kind|
      punch = @employee.valid_punches.find_by(kind: kind, work_date: @employee.work_date_for(kind, now))
      [kind, punch.local_time.strftime('%H:%M')] if punch
    end.to_h
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
