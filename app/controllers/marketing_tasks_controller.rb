class MarketingTasksController < ApplicationController
  before_action :set_task, only: [:show, :update, :start_work, :mark_converted, :mark_not_converted, :add_note]
  before_action :check_marketing_access
  before_action :redirect_agent_from_dashboard, only: [:index, :dashboard]

  def index
    @tasks = filter_tasks
    @stats = calculate_user_stats
    @campaigns = MarketingCampaign.status_active
  end

  def my_tasks
    @tasks = current_user.marketing_tasks
                        .includes(:marketing_campaign)
                        .order(created_at: :desc)
    
    # Apply status filter if provided
    @tasks = @tasks.where(status: params[:status]) if params[:status].present?
    
    @stats = calculate_user_stats
    @campaigns = MarketingCampaign.status_active
                                  .joins(:campaign_users)
                                  .where(campaign_users: { user_id: current_user.id })
                                  .distinct
  end

  def dashboard
    @stats = calculate_user_stats
    @recent_tasks = current_user.marketing_tasks
                                .order(updated_at: :desc)
                                .limit(10)
    @pending_tasks = current_user.marketing_tasks.pending.count
    @in_progress_tasks = current_user.marketing_tasks.in_progress.count
    @completed_today = current_user.marketing_tasks
                                   .where('completed_at >= ?', Time.current.beginning_of_day)
                                   .count
  end

  def show
    @lead_data = parse_lead_data
    @notes = @task.notes || []
  end

  def update
    if @task.update(task_params)
      respond_to do |format|
        format.html { redirect_to marketing_task_path(@task), notice: 'Tarefa atualizada com sucesso!' }
        format.json { render json: { success: true, task: @task } }
      end
    else
      respond_to do |format|
        format.html { render :show, alert: 'Erro ao atualizar tarefa.' }
        format.json { render json: { success: false, errors: @task.errors }, status: :unprocessable_entity }
      end
    end
  end

  def start_work
    unless @task.can_be_started_by?(current_user)
      redirect_to marketing_task_path(@task), alert: 'Você não pode iniciar esta tarefa!'
      return
    end

    @task.update!(
      status: 'in_progress',
      started_at: Time.current
    )

    redirect_to marketing_task_path(@task), notice: 'Trabalho iniciado!'
  end

  def mark_converted
    order_number = params[:order_number]
    
    if order_number.blank?
      redirect_to marketing_task_path(@task), alert: 'Número do pedido é obrigatório!'
      return
    end

    @task.update!(
      status: 'converted',
      converted: true,
      order_number: order_number,
      completed_at: Time.current
    )

    redirect_to marketing_task_path(@task), notice: 'Tarefa marcada como convertida!'
  end

  def mark_not_converted
    reason = params[:reason]

    @task.update!(
      status: 'completed',
      converted: false,
      completed_at: Time.current,
      notes: (@task.notes || []) << {
        user: current_user.name,
        timestamp: Time.current,
        content: "Não convertido: #{reason}"
      }
    )

    redirect_to marketing_task_path(@task), notice: 'Tarefa marcada como não convertida!'
  end

  def add_note
    note_content = params[:note]
    
    if note_content.blank?
      redirect_to marketing_task_path(@task), alert: 'Nota não pode estar vazia!'
      return
    end

    notes = @task.notes || []
    notes << {
      user: current_user.name,
      timestamp: Time.current,
      content: note_content
    }

    @task.update!(notes: notes)

    respond_to do |format|
      format.html { redirect_to marketing_task_path(@task), notice: 'Nota adicionada!' }
      format.json { render json: { success: true, notes: @task.notes } }
    end
  end

  def export
    @tasks = filter_tasks
    
    respond_to do |format|
      format.csv do
        send_data generate_csv(@tasks), filename: "marketing_tasks_#{Date.current}.csv"
      end
      format.json { render json: @tasks }
    end
  end

  private

  def set_task
    @task = MarketingTask.find(params[:id])
  end

  def task_params
    params.require(:marketing_task).permit(:status, :notes, :order_number, :converted)
  end

  def check_marketing_access
    unless current_user.admin? || current_user.agent_marketing? || current_user.admin_marketing?
      redirect_to root_path, alert: 'Acesso negado!'
    end
  end

  def filter_tasks
    tasks = MarketingTask.all

    tasks = tasks.where(marketing_campaign_id: params[:campaign_id]) if params[:campaign_id].present?
    tasks = tasks.where(status: params[:status]) if params[:status].present?
    tasks = tasks.where(user_id: params[:user_id]) if params[:user_id].present?
    tasks = tasks.where('created_at >= ?', params[:start_date]) if params[:start_date].present?
    tasks = tasks.where('created_at <= ?', params[:end_date]) if params[:end_date].present?

    tasks.includes(:marketing_campaign, :user).order(created_at: :desc)
  end

  def calculate_user_stats
    tasks = (current_user.admin? || current_user.admin_marketing?) ? MarketingTask.all : current_user.marketing_tasks
    
    {
      total: tasks.count,
      pending: tasks.pending.count,
      in_progress: tasks.in_progress.count,
      completed: tasks.completed.count,
      converted: tasks.converted.count,
      not_converted: tasks.not_converted.count,
      conversion_rate: calculate_conversion_rate(tasks),
      completed_today: tasks.where('completed_at >= ?', Time.current.beginning_of_day).count,
      avg_completion_time: calculate_avg_completion_time(tasks)
    }
  end

  def calculate_conversion_rate(tasks)
    completed = tasks.completed.count
    return 0 if completed.zero?
    
    converted = tasks.converted.count
    (converted.to_f / completed * 100).round(2)
  end

  def calculate_avg_completion_time(tasks)
    completed_tasks = tasks.completed.where.not(started_at: nil, completed_at: nil)
    return 0 if completed_tasks.empty?

    total_time = completed_tasks.sum { |t| (t.completed_at - t.started_at).to_i }
    (total_time / completed_tasks.count / 3600.0).round(2) # em horas
  end

  def parse_lead_data
    return {} if @task.lead_data.blank?
    @task.lead_data
  end

  def generate_csv(tasks)
    CSV.generate(headers: true) do |csv|
      csv << ['ID', 'Campanha', 'Tipo', 'Status', 'Usuário', 'Convertido', 'Pedido', 'Criado em', 'Completado em']
      
      tasks.each do |task|
        csv << [
          task.id,
          task.marketing_campaign.name,
          task.task_type,
          task.status,
          task.user&.name,
          task.converted? ? 'Sim' : 'Não',
          task.order_number,
          task.created_at.strftime('%d/%m/%Y %H:%M'),
          task.completed_at&.strftime('%d/%m/%Y %H:%M')
        ]
      end
    end
  end

  def redirect_agent_from_dashboard
    if current_user.agent_marketing?
      redirect_to my_tasks_marketing_tasks_path
    end
  end
end
