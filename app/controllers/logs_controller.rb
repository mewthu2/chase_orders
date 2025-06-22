class LogsController < ApplicationController
  before_action :authenticate_user!
  before_action :admin_only!

  def index
    @logs = filter_logs
    @per_page = 20
    @page = (params[:page] || 1).to_i
    @page = 1 if @page < 1
    
    @total_count = @logs.count
    @total_pages = (@total_count.to_f / @per_page).ceil
    @page = @total_pages if @page > @total_pages && @total_pages > 0
    
    offset = (@page - 1) * @per_page
    @logs = @logs.limit(@per_page).offset(offset)
    
    @prev_page = @page > 1 ? @page - 1 : nil
    @next_page = @page < @total_pages ? @page + 1 : nil
  end

  private

  def filter_logs
    logs = Log.includes(:user)

    if params[:search].present?
      search_term = "%#{params[:search]}%"
      logs = logs.joins(:user).where(
        'logs.resource_name ILIKE ? OR logs.resource_id ILIKE ? OR logs.details ILIKE ? OR users.name ILIKE ? OR logs.ip_address ILIKE ?',
        search_term, search_term, search_term, search_term, search_term
      )
    end

    if params[:user_id].present?
      logs = logs.where(user_id: params[:user_id])
    end

    if params[:action_type].present?
      logs = logs.where(action_type: params[:action_type])
    end

    if params[:resource_type].present?
      logs = logs.where(resource_type: params[:resource_type])
    end

    if params[:success].present?
      case params[:success]
      when 'true'
        logs = logs.where(success: true)
      when 'false'
        logs = logs.where(success: false)
      end
    end

    if params[:date_from].present?
      begin
        date_from = Date.parse(params[:date_from]).beginning_of_day
        logs = logs.where('logs.created_at >= ?', date_from)
      rescue ArgumentError
        # Invalid date format, ignore filter
      end
    end

    if params[:date_to].present?
      begin
        date_to = Date.parse(params[:date_to]).end_of_day
        logs = logs.where('logs.created_at <= ?', date_to)
      rescue ArgumentError
        # Invalid date format, ignore filter
      end
    end

    if params[:sort].present?
      direction = params[:direction] == 'desc' ? 'DESC' : 'ASC'
      case params[:sort]
      when 'created_at'
        logs = logs.order("logs.created_at #{direction}")
      when 'user'
        logs = logs.joins(:user).order("users.name #{direction}")
      when 'action_type'
        logs = logs.order("logs.action_type #{direction}")
      when 'resource_type'
        logs = logs.order("logs.resource_type #{direction}")
      when 'resource_name'
        logs = logs.order("logs.resource_name #{direction}")
      when 'success'
        logs = logs.order("logs.success #{direction}")
      end
    else
      logs = logs.order(created_at: :desc)
    end

    logs
  end

  def admin_only!
    unless current_user&.admin?
      redirect_to root_path, alert: 'Acesso negado. Apenas administradores podem acessar esta funcionalidade.'
    end
  end
end