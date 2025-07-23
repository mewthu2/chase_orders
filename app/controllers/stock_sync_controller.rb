class StockSyncController < ApplicationController
  before_action :set_config, only: [:show, :update_config, :execute_now, :toggle_status]

  def index
    @config = StockSyncConfig.current_config
    @recent_attempts = Attempt.where(kinds: :sync_correios_stock)
                              .order(created_at: :desc)
                              .limit(20)
    @stats = calculate_stats
    @current_execution = current_execution
  end

  def update_config
    params[:stock_sync_config][:days_of_week] ||= []
    params[:stock_sync_config][:hours] ||= []

    config_params_processed = config_params.dup
    config_params_processed[:days_of_week] = config_params_processed[:days_of_week].map(&:to_i).to_json
    config_params_processed[:hours] = config_params_processed[:hours].map(&:to_i).to_json

    if @config.update(config_params_processed)
      redirect_to stock_sync_index_path, notice: 'Configuração atualizada com sucesso!'
    else
      @recent_attempts = Attempt.where(kinds: :sync_correios_stock)
                                .order(created_at: :desc)
                                .limit(20)
      @stats = calculate_stats
      @current_execution = current_execution
      render :index, alert: 'Erro ao atualizar configuração.'
    end
  end

  def execute_now
    if current_execution
      redirect_to stock_sync_index_path, alert: 'Já existe uma sincronização em execução!'
      return
    end

    attempt = Attempt.create!(
      kinds: :sync_correios_stock,
      status: :processing,
      tracking: "manual_execution:#{Time.current.to_i}",
      message: "Execução manual iniciada pelo usuário #{current_user.name}"
    )

    UpdateShopifyStockFromCorreiosJob.perform_later(attempt.id)

    redirect_to stock_sync_index_path, notice: 'Sincronização iniciada manualmente!'
  end

  def toggle_status
    @config.update!(enabled: !@config.enabled?)
    status = @config.enabled? ? 'ativada' : 'desativada'
    redirect_to stock_sync_index_path, notice: "Sincronização automática #{status}!"
  end

  private

  def set_config
    @config = StockSyncConfig.current_config
  end

  def config_params
    params.require(:stock_sync_config).permit(days_of_week: [], hours: [])
  end

  def current_execution
    Attempt.where(kinds: 7, status: :processing)
           .order(created_at: :desc)
           .first
  end

  def calculate_stats
    attempts = Attempt.where(kinds: 7)

    {
      total: attempts.count,
      success: attempts.where(status: :success).count,
      failed: attempts.where(status: [:fail, :error]).count,
      processing: attempts.where(status: :processing).count,
      last_execution: attempts.order(created_at: :desc).first&.created_at,
      success_rate: attempts.count.zero? ? (attempts.where(status: :success).count.to_f / attempts.count * 100).round(1) : 0
    }
  end
end
