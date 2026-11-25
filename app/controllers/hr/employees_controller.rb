module Hr
  # Recursos Humanos › Funcionários: cadastro por empresa e estado, carga horária e horários, o link do ponto
  # de cada um e o espelho de ponto do mês (com as fotos, o total de cada dia e o saldo).
  class EmployeesController < ApplicationController
    guard_screen :hr_employees, actions: { regenerate_link: :edit }
    before_action :set_employee, only: %i[show edit update destroy regenerate_link]

    def index
      @employees = HrEmployee.includes(:company).ordered.to_a
      ids = @employees.map(&:id)
      @open_now = HrTimePunch.effective.where(hr_employee_id: ids, work_date: [Date.yesterday, Date.current, Date.tomorrow])
                             .where('punched_at > ?', 16.hours.ago).order(:punched_at).group_by(&:hr_employee_id)
                             .select { |_, list| list.last.in? }.keys
      @week_alerts = HrAlert.where(hr_employee_id: ids, work_date: 6.days.ago.to_date.beginning_of_week(:monday)..).group(:hr_employee_id).count
    end

    def show
      @month = month_param
      range = @month.beginning_of_month..@month.end_of_month
      punches = @employee.time_punches.where(work_date: range).includes(:created_by, :annulled_by, photo_attachment: :blob).chronological.to_a
      @punches_by_day = punches.group_by(&:work_date)
      @days = range.map { |date| [date, WorkDay.new(@employee, date, @punches_by_day[date].to_a.reject(&:annulled?))] }
      @alerts = @employee.alerts.where(work_date: (range.first - 6)..range.last).recent.to_a
      respond_to do |format|
        format.html
        format.csv { send_data mirror_csv, filename: "espelho-ponto-#{@employee.name.parameterize}-#{@month.strftime('%Y-%m')}.csv", type: 'text/csv' }
      end
    end

    def new
      @employee = HrEmployee.new(weekly_minutes: 44 * 60, schedule: default_schedule, state: 'MG', company: Company.active.first)
    end

    def create
      @employee = HrEmployee.new(employee_params)
      if @employee.save
        redirect_to hr_employee_path(@employee), notice: "#{@employee.name} cadastrado(a). Mande o link do ponto para a pessoa."
      else
        render :new, status: :unprocessable_content
      end
    end

    def edit; end

    def update
      if @employee.update(employee_params)
        redirect_to hr_employee_path(@employee), notice: "Cadastro de #{@employee.name} atualizado."
      else
        render :edit, status: :unprocessable_content
      end
    end

    def destroy
      if @employee.time_punches.exists?
        @employee.update!(active: false)
        return redirect_to(hr_employee_path(@employee), notice: "#{@employee.name} tem marcações de ponto, que a lei manda guardar: o cadastro foi desativado e o link parou de funcionar.")
      end

      @employee.destroy!
      redirect_to hr_employees_path, notice: "#{@employee.name} excluído(a)."
    end

    def regenerate_link
      @employee.regenerate_token!
      redirect_to hr_employee_path(@employee), notice: 'Link novo gerado. O link antigo parou de funcionar: mande o novo para a pessoa.'
    end

    private

    def set_employee
      @employee = HrEmployee.includes(:company).find(params[:id])
    end

    def employee_params
      permitted = params.require(:hr_employee).permit(:name, :cpf, :role, :email, :phone, :user_id, :company_id, :state, :admission_date, :weekly_hours, :active,
                                                      schedule: HrEmployee::WEEKDAYS.keys.to_h { |d| [d, HrEmployee::TIME_FIELDS] })
      permitted[:schedule] = permitted[:schedule].to_h if permitted.key?(:schedule)
      permitted
    end

    def default_schedule
      (1..5).to_h { |d| [d.to_s, { 'in' => '08:00', 'break_start' => '12:00', 'break_end' => '13:00', 'out' => '17:48' }] }
    end

    def month_param
      Date.strptime(params[:mes].to_s, '%Y-%m')
    rescue Date::Error
      @employee.today.beginning_of_month
    end

    def mirror_csv
      require 'csv'
      CSV.generate(col_sep: ';') do |csv|
        csv << ['Funcionário', @employee.name, 'CPF', @employee.cpf_formatted, 'Empresa', @employee.company_name, 'Estado', @employee.state]
        csv << ['Data', 'Dia', 'Previsto', 'Marcações', 'Trabalhado', 'Intervalo', 'Saldo', 'Observação']
        @days.each do |date, day|
          marks = @punches_by_day[date].to_a.reject(&:annulled?).map { |p| "#{p.local_time.strftime('%H:%M')}#{' (RH)' if p.manual?}" }.join(' ')
          csv << [date.strftime('%d/%m/%Y'), I18n.l(date, format: '%a'), HrEmployee.hours(day.expected_minutes), marks,
                  HrEmployee.hours(day.worked_minutes), HrEmployee.hours(day.break_minutes), HrEmployee.hours(day.balance, sign: true),
                  (day.incomplete? ? 'Marcação faltando' : nil)]
        end
        total = @days.sum { |_, d| d.balance }
        csv << ['Total', nil, HrEmployee.hours(@days.sum { |_, d| d.expected_minutes }), nil, HrEmployee.hours(@days.sum { |_, d| d.worked_minutes }), nil, HrEmployee.hours(total, sign: true)]
      end
    end
  end
end
