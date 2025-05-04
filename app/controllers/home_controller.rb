class HomeController < ApplicationController
  def index
    redirect_to new_user_session_path and return unless current_user
    
    # Definir os tipos de pedidos
    @kinds = ['rj', 'bh_shopping', 'lagoa_seca']
    
    # Calcular datas para os períodos
    @today_start = Date.today.beginning_of_day
    @today_end = Date.today.end_of_day
    @week_start = 7.days.ago.beginning_of_day
    @month_start = 30.days.ago.beginning_of_day
    
    # Carregar todos os dados necessários em consultas otimizadas
    load_dashboard_data
    
    # Preparar dados para os gráficos ApexCharts
    prepare_chart_data
    
    # Carregar os últimos pedidos migrados para cada tipo
    load_recent_migrated_orders
  end
  
  private
  
  def load_dashboard_data
    # Consulta única para obter contagens totais
    @total_orders = Order.count
    @total_migrated = Order.where.not(shopify_order_id: nil).count
    @total_not_migrated = Order.where(shopify_order_id: nil).count
    @migration_percentage = @total_orders > 0 ? (@total_migrated.to_f / @total_orders * 100).round : 0
    
    # Inicializar estatísticas
    @today_stats = {}
    @week_stats = {}
    @month_stats = {}
    
    # Calcular estatísticas para cada tipo e período
    @kinds.each do |kind|
      # Estatísticas para hoje
      today_scope = Order.where(kinds: kind).where(created_at: @today_start..@today_end)
      today_total = today_scope.count
      today_migrated = today_scope.where.not(shopify_order_id: nil).count
      today_not_migrated = today_total - today_migrated
      today_percentage = today_total > 0 ? (today_migrated.to_f / today_total * 100).round : 0
      
      @today_stats[kind] = {
        total: today_total,
        migrated: today_migrated,
        not_migrated: today_not_migrated,
        migration_percentage: today_percentage
      }
      
      # Estatísticas para a semana
      week_scope = Order.where(kinds: kind).where(created_at: @week_start..@today_end)
      week_total = week_scope.count
      week_migrated = week_scope.where.not(shopify_order_id: nil).count
      week_not_migrated = week_total - week_migrated
      week_percentage = week_total > 0 ? (week_migrated.to_f / week_total * 100).round : 0
      
      @week_stats[kind] = {
        total: week_total,
        migrated: week_migrated,
        not_migrated: week_not_migrated,
        migration_percentage: week_percentage
      }
      
      # Estatísticas para o mês
      month_scope = Order.where(kinds: kind).where(created_at: @month_start..@today_end)
      month_total = month_scope.count
      month_migrated = month_scope.where.not(shopify_order_id: nil).count
      month_not_migrated = month_total - month_migrated
      month_percentage = month_total > 0 ? (month_migrated.to_f / month_total * 100).round : 0
      
      @month_stats[kind] = {
        total: month_total,
        migrated: month_migrated,
        not_migrated: month_not_migrated,
        migration_percentage: month_percentage
      }
    end
    
    # Calcular totais gerais para cada período
    today_total_scope = Order.where(created_at: @today_start..@today_end)
    today_total = today_total_scope.count
    today_migrated = today_total_scope.where.not(shopify_order_id: nil).count
    today_not_migrated = today_total - today_migrated
    today_percentage = today_total > 0 ? (today_migrated.to_f / today_total * 100).round : 0
    
    @today_stats['total'] = {
      total: today_total,
      migrated: today_migrated,
      not_migrated: today_not_migrated,
      migration_percentage: today_percentage
    }
    
    week_total_scope = Order.where(created_at: @week_start..@today_end)
    week_total = week_total_scope.count
    week_migrated = week_total_scope.where.not(shopify_order_id: nil).count
    week_not_migrated = week_total - week_migrated
    week_percentage = week_total > 0 ? (week_migrated.to_f / week_total * 100).round : 0
    
    @week_stats['total'] = {
      total: week_total,
      migrated: week_migrated,
      not_migrated: week_not_migrated,
      migration_percentage: week_percentage
    }
    
    month_total_scope = Order.where(created_at: @month_start..@today_end)
    month_total = month_total_scope.count
    month_migrated = month_total_scope.where.not(shopify_order_id: nil).count
    month_not_migrated = month_total - month_migrated
    month_percentage = month_total > 0 ? (month_migrated.to_f / month_total * 100).round : 0
    
    @month_stats['total'] = {
      total: month_total,
      migrated: month_migrated,
      not_migrated: month_not_migrated,
      migration_percentage: month_percentage
    }
    
    # Calcular estatísticas adicionais para cada tipo
    @kinds_stats = {}
    
    @kinds.each do |kind|
      # Contagem total para este tipo
      total = Order.where(kinds: kind).count
      
      # Contagem de pedidos migrados para este tipo
      migrated = Order.where(kinds: kind).where.not(shopify_order_id: nil).count
      
      # Contagem de pedidos não migrados para este tipo
      not_migrated = Order.where(kinds: kind).where(shopify_order_id: nil).count
      
      # Porcentagem de migração
      migration_percentage = total > 0 ? (migrated.to_f / total * 100).round : 0
      
      # Pedidos migrados hoje
      migrated_today = Order.where(kinds: kind)
                            .where.not(shopify_order_id: nil)
                            .where(created_at: @today_start..@today_end)
                            .count
      
      # Pedidos migrados esta semana
      migrated_week = Order.where(kinds: kind)
                           .where.not(shopify_order_id: nil)
                           .where(created_at: @week_start..@today_end)
                           .count
      
      # Pedidos migrados este mês
      migrated_month = Order.where(kinds: kind)
                            .where.not(shopify_order_id: nil)
                            .where(created_at: @month_start..@today_end)
                            .count
      
      # Data da última migração
      last_migrated = Order.where(kinds: kind)
                           .where.not(shopify_order_id: nil)
                           .order(updated_at: :desc)
                           .first&.updated_at
      
      @kinds_stats[kind] = {
        total: total,
        migrated: migrated,
        not_migrated: not_migrated,
        migration_percentage: migration_percentage,
        migrated_today: migrated_today,
        migrated_week: migrated_week,
        migrated_month: migrated_month,
        last_migrated: last_migrated
      }
    end
  end
  
  def prepare_chart_data
    # Dados para o gráfico de linha (últimos 30 dias)
    @daily_migration_data = get_daily_migration_data
    
    # Dados para o gráfico de barras (comparação por tipo)
    @kind_comparison_data = {
      categories: @kinds.map { |kind| kind_display_name(kind) },
      series: [
        {
          name: 'Hoje',
          data: @kinds.map { |kind| @today_stats[kind][:migrated] }
        },
        {
          name: 'Últimos 7 dias',
          data: @kinds.map { |kind| @week_stats[kind][:migrated] }
        },
        {
          name: 'Últimos 30 dias',
          data: @kinds.map { |kind| @month_stats[kind][:migrated] }
        }
      ]
    }
  end
  
  def get_daily_migration_data
    # Gerar array de datas para os últimos 30 dias
    dates = []
    date_range = (@month_start.to_date..@today_end.to_date)
    
    # Inicializar contagens para cada kind
    migrated_counts = {}
    @kinds.each do |kind|
      migrated_counts[kind] = {}
      date_range.each do |date|
        migrated_counts[kind][date.strftime('%d/%m')] = 0
      end
    end
    
    # Consulta otimizada para obter contagens diárias por kind
    @kinds.each do |kind|
      date_range.each do |date|
        day_start = date.beginning_of_day
        day_end = date.end_of_day
        
        # Contar pedidos migrados para este kind neste dia
        count = Order.where(kinds: kind)
                     .where.not(shopify_order_id: nil)
                     .where(created_at: day_start..day_end)
                     .count
        
        migrated_counts[kind][date.strftime('%d/%m')] = count
      end
    end
    
    # Formatar datas para o eixo X
    formatted_dates = date_range.map { |date| date.strftime('%d/%m') }
    
    # Formatar dados para ApexCharts
    series = @kinds.map do |kind|
      {
        name: kind_display_name(kind),
        data: formatted_dates.map { |date| migrated_counts[kind][date] }
      }
    end
    
    {
      dates: formatted_dates,
      series: series
    }
  end
  
  def load_recent_migrated_orders
    @recent_migrated_orders = {}
    
    @kinds.each do |kind|
      # Buscar os últimos 5 pedidos migrados para este tipo
      @recent_migrated_orders[kind] = Order.where(kinds: kind)
                                          .where.not(shopify_order_id: nil)
                                          .order(updated_at: :desc)
                                          .limit(5)
                                          .includes(:order_items) # Eager loading para evitar N+1
    end
  end
  
  def kind_display_name(kind)
    case kind
    when 'rj'
      'Rio de Janeiro'
    when 'bh_shopping'
      'BH Shopping'
    when 'lagoa_seca'
      'Lagoa Seca'
    else
      kind.titleize
    end
  end
end
