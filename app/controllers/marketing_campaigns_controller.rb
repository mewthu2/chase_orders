class MarketingCampaignsController < ApplicationController
  before_action :set_campaign, only: [:edit, :update, :destroy, :toggle_status, :add_user, :remove_user, :statistics]
  before_action :check_admin_marketing_access

  def index
    @campaigns = MarketingCampaign.includes(:campaign_users, :marketing_tasks)
                                  .order(created_at: :desc)
    @stats = calculate_global_stats
  end

  def new
    @campaign = MarketingCampaign.new
  end

  def create
    @campaign = MarketingCampaign.new(campaign_params)
    @campaign.created_by_id = current_user.id
    
    if @campaign.save
      redirect_to edit_marketing_campaign_path(@campaign), notice: 'Campanha criada com sucesso!'
    else
      render :new, alert: 'Erro ao criar campanha.'
    end
  end

  def edit
    @campaign_users = @campaign.campaign_users.includes(:user)
    @tasks = @campaign.marketing_tasks.includes(:user)
                      .order(created_at: :desc)
                      .limit(50)
    @stats = calculate_campaign_stats
    @available_users = User.where(profile_id: [5, 6])
                           .where.not(id: @campaign.campaign_users.pluck(:user_id))
  end

  def update
    if @campaign.update(campaign_params)
      redirect_to edit_marketing_campaign_path(@campaign), notice: 'Campanha atualizada com sucesso!'
    else
      render :edit, alert: 'Erro ao atualizar campanha.'
    end
  end

  def destroy
    @campaign.destroy
    redirect_to marketing_campaigns_path, notice: 'Campanha removida com sucesso!'
  end

  def toggle_status
    new_status = @campaign.active? ? 'inactive' : 'active'
    @campaign.update!(status: new_status)
    status_text = @campaign.active? ? 'ativada' : 'desativada'

    respond_to do |format|
      format.html { redirect_to edit_marketing_campaign_path(@campaign), notice: "Campanha #{status_text}!" }
      format.json { render json: { success: true, status: @campaign.status, message: "Campanha #{status_text}!" } }
    end
  rescue StandardError => e
    Rails.logger.error "Erro ao alterar status da campanha: #{e.message}"

    respond_to do |format|
      format.html { redirect_to edit_marketing_campaign_path(@campaign), alert: 'Erro ao alterar status da campanha.' }
      format.json { render json: { success: false, message: 'Erro ao alterar status.' }, status: :unprocessable_entity }
    end
  end

  def add_user
    user = User.find(params[:user_id])
    
    unless [5, 6].include?(user.profile_id)
      redirect_to edit_marketing_campaign_path(@campaign), alert: 'Usuário não possui perfil de marketing!'
      return
    end

    campaign_user = @campaign.campaign_users.build(user: user)
    
    if campaign_user.save
      redirect_to edit_marketing_campaign_path(@campaign), notice: 'Usuário adicionado à campanha!'
    else
      redirect_to edit_marketing_campaign_path(@campaign), alert: 'Erro ao adicionar usuário.'
    end
  end

  def remove_user
    campaign_user = @campaign.campaign_users.find_by(user_id: params[:user_id])
    
    if campaign_user&.destroy
      redirect_to edit_marketing_campaign_path(@campaign), notice: 'Usuário removido da campanha!'
    else
      redirect_to edit_marketing_campaign_path(@campaign), alert: 'Erro ao remover usuário.'
    end
  end

  def statistics
    @stats = calculate_detailed_campaign_stats
    @tasks_by_status = @campaign.marketing_tasks.group(:status).count
    @tasks_by_user = @campaign.marketing_tasks.joins(:user).group('users.name').count
    @recent_conversions = @campaign.marketing_tasks.converted.order(completed_at: :desc).limit(10)
    @top_performers = calculate_top_performers
  end

  private

  def set_campaign
    @campaign = MarketingCampaign.find(params[:id])
  end

  def campaign_params
    params.require(:marketing_campaign).permit(
      :name,
      :start_date,
      :end_date,
      :objective,
      :campaign_type,
      :users_per_week,
      :status,
      :active
    )
  end

  def check_admin_marketing_access
    unless current_user.admin? || current_user.admin_marketing?
      redirect_to root_path, alert: 'Acesso negado!'
    end
  end

  def calculate_global_stats
    {
      total_campaigns: MarketingCampaign.count,
      active_campaigns: MarketingCampaign.status_active.count,
      total_tasks: MarketingTask.count,
      completed_tasks: MarketingTask.completed.count,
      converted_tasks: MarketingTask.converted.count,
      pending_tasks: MarketingTask.pending.count,
      in_progress_tasks: MarketingTask.in_progress.count,
      conversion_rate: calculate_conversion_rate,
      total_revenue: 0
    }
  end

  def calculate_campaign_stats
    {
      total_tasks: @campaign.marketing_tasks.count,
      pending: @campaign.marketing_tasks.pending.count,
      in_progress: @campaign.marketing_tasks.in_progress.count,
      completed: @campaign.marketing_tasks.completed.count,
      converted: @campaign.marketing_tasks.converted.count,
      not_converted: @campaign.marketing_tasks.not_converted.count,
      conversion_rate: @campaign.conversion_rate,
      total_users: @campaign.campaign_users.count
    }
  end

  def calculate_conversion_rate
    total = MarketingTask.completed.count
    return 0 if total.zero?
    
    converted = MarketingTask.converted.count
    (converted.to_f / total * 100).round(2)
  end

  def calculate_detailed_campaign_stats
    tasks = @campaign.marketing_tasks
    completed_tasks = tasks.completed
    
    {
      total_tasks: tasks.count,
      pending: tasks.pending.count,
      in_progress: tasks.in_progress.count,
      completed: completed_tasks.count,
      converted: tasks.converted.count,
      not_converted: tasks.not_converted.count,
      conversion_rate: @campaign.conversion_rate,
      total_users: @campaign.campaign_users.count,
      avg_completion_time: calculate_avg_completion_time_for_campaign(completed_tasks),
      tasks_this_week: tasks.where('created_at >= ?', 1.week.ago).count,
      conversions_this_week: tasks.converted.where('completed_at >= ?', 1.week.ago).count
    }
  end

  def calculate_avg_completion_time_for_campaign(completed_tasks)
    tasks_with_time = completed_tasks.where.not(started_at: nil, completed_at: nil)
    return 0 if tasks_with_time.empty?

    total_time = tasks_with_time.sum { |t| (t.completed_at - t.started_at).to_i }
    (total_time / tasks_with_time.count / 3600.0).round(2) # em horas
  end

  def calculate_top_performers
    @campaign.marketing_tasks
             .joins(:user)
             .group('users.id', 'users.name')
             .select('users.id, users.name, 
                      COUNT(*) as total_tasks,
                      SUM(CASE WHEN marketing_tasks.converted = true THEN 1 ELSE 0 END) as conversions,
                      (SUM(CASE WHEN marketing_tasks.converted = true THEN 1 ELSE 0 END) * 100.0 / COUNT(*)) as conversion_rate')
             .order('conversions DESC')
             .limit(5)
  end
end
