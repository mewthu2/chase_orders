require 'test_helper'
require_relative '../support/finance_factory'

# Recursos Humanos: funcionários, ponto com foto pelo link, espelho e alertas de jornada da CLT.
class HrTest < ActionDispatch::IntegrationTest
  include FinanceFactory
  include ActiveJob::TestHelper

  PHOTO = "data:image/jpeg;base64,#{Base64.strict_encode64("\xFF\xD8\xFF\xE0fake-jpeg".b)}".freeze
  WEEK = (1..5).to_h { |d| [d.to_s, { 'in' => '08:00', 'break_start' => '12:00', 'break_end' => '13:00', 'out' => '17:48' }] }.freeze

  def setup
    @admin = finance_user('Admin RH')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @company = Company.new(legal_name: 'CHASE LTDA', trade_name: 'Chase BH', cnpj: '25.405.327/0001-74', street: 'R', number: '1',
                           neighbourhood: 'B', city: 'BH', city_ibge_code: '3106200', state: 'MG', zip: '30000000')
    @company.save!(validate: false)
    @employee = HrEmployee.create!(name: 'Ana Souza', company: @company, state: 'MG', weekly_minutes: 44 * 60, schedule: WEEK, phone: '31999998888')
  end

  def punch!(kind, at, employee: @employee)
    employee.time_punches.create!(kind: kind, punched_at: at, work_date: at.in_time_zone(employee.time_zone).to_date, source: 'manual', note: 'teste')
  end

  def local(str, employee: @employee) = employee.time_zone.parse(str)

  test 'horarios seguem a CLT: 10h no dia, intervalo acima de 6h e carga semanal' do
    e = HrEmployee.new(name: 'X', company: @company, state: 'MG', weekly_minutes: 44 * 60,
                       schedule: { '1' => { 'in' => '07:00', 'out' => '18:30', 'break_start' => '12:00', 'break_end' => '13:00' } })
    refute e.valid?
    assert_match '10h por dia', e.errors.full_messages.join
    e.schedule = { '1' => { 'in' => '08:00', 'out' => '16:00' } }
    refute e.valid?
    assert_match 'intervalo de pelo menos 1h', e.errors.full_messages.join
    e.schedule = WEEK
    e.weekly_minutes = 40 * 60
    refute e.valid?
    assert_match 'mais que a carga', e.errors.full_messages.join
    e.weekly_hours = '44'
    assert e.valid?, e.errors.full_messages.join
    e.weekly_hours = '45'
    refute e.valid?
    e.cpf = '111.111.111-11'
    e.weekly_hours = '44'
    refute e.valid?
    e.cpf = '529.982.247-25'
    assert e.valid?
    assert_equal 'America/Manaus', HrEmployee::STATE_ZONES['AM']
  end

  test 'link do ponto pede login e so abre para o usuario ligado ao funcionario' do
    get punch_clock_path(@employee.punch_token)
    assert_redirected_to new_user_session_path
    post punch_clock_path(@employee.punch_token), params: { kind: 'entrada', photo: PHOTO }, as: :json
    assert_response :unauthorized
    assert_match 'Honey', response.parsed_body['error']

    sign_in @admin
    get punch_clock_path(@employee.punch_token)
    assert_response :forbidden
    assert_match 'não está ligado', response.body

    ana = finance_user('Ana Souza')
    @employee.update!(user: ana)
    get punch_clock_path(@employee.punch_token)
    assert_response :forbidden
    assert_match 'outra pessoa', response.body
    assert_no_difference -> { HrTimePunch.count } do
      post punch_clock_path(@employee.punch_token), params: { kind: 'entrada', photo: PHOTO }, as: :json
    end
    assert_response :forbidden

    other = HrEmployee.new(name: 'Bia', company: @company, state: 'MG', weekly_minutes: 60, schedule: WEEK, user: ana)
    refute other.valid?
    assert other.errors[:user_id].any?
  end

  test 'link do ponto abre a camera e grava a marcacao com foto, nsr e horario do servidor' do
    ana = finance_user('Ana Souza')
    @employee.update!(user: ana)
    sign_in ana
    get punch_clock_path(@employee.punch_token)
    assert_response :success
    assert_select '.pc-kind.is-suggested input[value=entrada]'
    assert_match 'getUserMedia', response.body

    assert_enqueued_with(job: HrJourneyCheckJob) do
      post punch_clock_path(@employee.punch_token), params: { kind: 'entrada', photo: PHOTO }, as: :json
    end
    assert_response :success
    body = response.parsed_body
    assert body['ok']
    punch = @employee.time_punches.last
    assert punch.photo.attached?
    assert_equal 'link', punch.source
    assert_equal body['punch']['nsr'], punch.nsr_text
    assert_in_delta Time.current, punch.punched_at, 5

    post punch_clock_path(@employee.punch_token), params: { kind: 'saida', photo: PHOTO }, as: :json
    assert_response :unprocessable_content
    assert_match 'acabou de bater', response.parsed_body['error']

    travel 2.minutes do
      post punch_clock_path(@employee.punch_token), params: { kind: 'saida' }, as: :json
      assert_match 'foto', response.parsed_body['error']

      # Uma foto por marcação no dia: a segunda Entrada é recusada e a tela mostra a Entrada como feita.
      assert_no_difference -> { @employee.time_punches.count } do
        post punch_clock_path(@employee.punch_token), params: { kind: 'entrada', photo: PHOTO }, as: :json
      end
      assert_response :unprocessable_content
      assert_match 'já bateu Entrada', response.parsed_body['error']
      get punch_clock_path(@employee.punch_token)
      assert_select '.pc-kind.is-done input[value=entrada][disabled]'
      assert_select '.pc-kind.is-suggested input[value=entrada]', count: 0
    end

    post punch_clock_path('nao-existe'), params: { kind: 'entrada', photo: PHOTO }, as: :json
    assert_response :not_found
    get punch_clock_path('nao-existe')
    assert_response :not_found

    @employee.update!(active: false)
    get punch_clock_path(@employee.punch_token)
    assert_response :not_found
  end

  test 'acima da carga do dia e sem intervalo gera alerta e email para o rh uma vez so' do
    monday = Date.new(2026, 11, 23)
    punch!('entrada', local("#{monday} 08:00"))
    punch!('saida', local("#{monday} 18:30"))
    now = local("#{monday} 19:00")
    created = nil
    assert_emails 1 do
      created = Hr::JourneyCheck.call(@employee, monday, now: now)
    end
    assert_equal %w[break_short daily_limit daily_over].sort, created.map(&:kind).sort
    mail = ActionMailer::Base.deliveries.last
    assert_equal ['atendimento@chasebrasil.com'], mail.to
    assert_match 'Ana Souza', mail.subject
    assert HrAlert.where(kind: 'daily_over').first.notified_at

    assert_no_emails { Hr::JourneyCheck.call(@employee, monday, now: now) }
  end

  test 'dentro da tolerancia nao alerta; folga, descanso de 11h e semana alertam' do
    monday = Date.new(2026, 11, 23)
    punch!('entrada', local("#{monday} 08:00"))
    punch!('saida_intervalo', local("#{monday} 12:00"))
    punch!('volta_intervalo', local("#{monday} 13:00"))
    punch!('saida', local("#{monday} 17:55"))
    assert_empty Hr::JourneyCheck.call(@employee, monday, now: local("#{monday} 20:00"), notify: false)

    tuesday = monday + 1
    punch!('entrada', local("#{tuesday} 03:00"))
    punch!('saida', local("#{tuesday} 06:00"))
    kinds = Hr::JourneyCheck.call(@employee, tuesday, now: local("#{tuesday} 07:00"), notify: false).map(&:kind)
    assert_includes kinds, 'rest_short'

    saturday = monday + 5
    punch!('entrada', local("#{saturday} 09:00"))
    punch!('saida', local("#{saturday} 11:00"))
    kinds = Hr::JourneyCheck.call(@employee, saturday, now: local("#{saturday} 12:00"), notify: false).map(&:kind)
    assert_includes kinds, 'day_off'

    (2..4).each do |i|
      d = monday + i
      punch!('entrada', local("#{d} 07:00"))
      punch!('saida_intervalo', local("#{d} 12:00"))
      punch!('volta_intervalo', local("#{d} 13:00"))
      punch!('saida', local("#{d} 19:00"))
    end
    kinds = Hr::JourneyCheck.call(@employee, monday + 4, now: local("#{monday + 4} 20:00"), notify: false).map(&:kind)
    assert_includes kinds, 'weekly_over'
    assert_equal monday, HrAlert.find_by(kind: 'weekly_over').work_date
  end

  test 'quem continua trabalhando sem bater a saida e conferido de novo no limite' do
    monday = Date.new(2026, 11, 23)
    punch!('entrada', local("#{monday} 08:00"))
    punch!('saida_intervalo', local("#{monday} 12:00"))
    punch!('volta_intervalo', local("#{monday} 13:00"))
    check = Hr::JourneyCheck.new(@employee, monday, now: local("#{monday} 17:00"))
    assert check.day.open?
    assert_equal 59, check.pending_thresholds.first # 17:48 + 10 min de tolerância + 1
    later = Hr::JourneyCheck.new(@employee, monday, now: local("#{monday} 18:10"))
    assert_equal ['daily_over'], later.call(notify: false).map(&:kind)
    assert_match 'ainda sem bater a saída', HrAlert.last.message
  end

  test 'telas do rh: lista, cadastro, espelho com foto, inclusao e desconsiderar' do
    sign_in @admin
    get hr_employees_path
    assert_response :success
    assert_select 'a', text: 'Ana Souza'

    get new_hr_employee_path
    assert_response :success
    post hr_employees_path, params: { hr_employee: { name: 'Bia Lima', company_id: @company.id, state: 'AM', weekly_hours: '44', schedule: WEEK } }
    bia = HrEmployee.find_by!(name: 'Bia Lima')
    assert_redirected_to hr_employee_path(bia)
    assert_equal 'America/Manaus', bia.time_zone.tzinfo.name

    post hr_employees_path, params: { hr_employee: { name: 'Sem Horario', company_id: @company.id, state: 'MG', weekly_hours: '44', schedule: {} } }
    assert_response :unprocessable_content

    @employee.update!(user: @admin)
    travel_to local('2026-11-24 10:00') do
      post punch_clock_path(@employee.punch_token), params: { kind: 'entrada', photo: PHOTO }, as: :json
      get hr_employee_path(@employee)
      assert_response :success
      assert_select '.hr-qr svg'
      assert_select '.hr-mark img'
      assert_match 'wa.me/5531999998888', response.body

      post hr_punches_path, params: { hr_employee_id: @employee.id, kind: 'saida', date: '2026-11-24', time: '09:00', note: '' }
      assert_match 'motivo', flash[:alert]
      post hr_punches_path, params: { hr_employee_id: @employee.id, kind: 'saida', date: '2026-11-23', time: '17:48', note: 'Esqueceu' }
      punch = HrTimePunch.find_by!(source: 'manual')
      assert_equal @admin, punch.created_by

      post annul_hr_punch_path(punch), params: { reason: '' }
      refute punch.reload.annulled?
      post annul_hr_punch_path(punch), params: { reason: 'Lançada errado' }
      assert punch.reload.annulled?
      assert HrTimePunch.exists?(punch.id)

      get hr_employee_path(@employee, format: :csv)
      assert_match 'Ana Souza', response.body
      get hr_punches_path
      assert_response :success
      assert_select '.hr-shot', 1
      get hr_alerts_path
      assert_response :success
    end

    old = @employee.punch_token
    post regenerate_link_hr_employee_path(@employee)
    refute_equal old, @employee.reload.punch_token

    delete hr_employee_path(@employee)
    assert HrEmployee.exists?(@employee.id)
    refute @employee.reload.active?
  end

  test 'perfil so do rh ve o rh e nada mais' do
    profile = Profile.create!(name: 'Recursos Humanos')
    profile.screen_actions = { 'hr_employees' => 'VCEDP', 'hr_punches' => 'VEP', 'hr_alerts' => 'V' }
    profile.save!
    rh = finance_user('Atendimento')
    rh.profiles = [profile]
    sign_in rh
    get hr_employees_path
    assert_response :success
    assert_select ".sb-section[data-area='rh']"
    assert_select ".sb-section[data-area='adm']", 0
    get clients_path
    assert_redirected_to root_path
  end
end
