class HomeController < ApplicationController
  def index
    redirect_to new_user_session_path and return unless current_user
    
    @kinds = ['rj', 'bh_shopping', 'lagoa_seca']
    
    @today = Date.today
    @week_ago = 7.days.ago.to_date
    @month_ago = 30.days.ago.to_date
    
    load_dashboard_data
    
    prepare_chart_data
    
    load_recent_migrated_orders
  end
  
  private
  
  def load_dashboard_data
    base_orders = Order.all
    
    @total_orders = base_orders.count
    @total_migrated = base_orders.where.not(shopify_order_id: nil).count
    @total_not_migrated = @total_orders - @total_migrated
    @migration_percentage = @total_orders > 0 ? (@total_migrated.to_f / @total_orders * 100).round : 0
    
    @today_stats = Hash.new { |h, k| h[k] = { total: 0, migrated: 0, not_migrated: 0, migration_percentage: 0 } }
    @week_stats = Hash.new { |h, k| h[k] = { total: 0, migrated: 0, not_migrated: 0, migration_percentage: 0 } }
    @month_stats = Hash.new { |h, k| h[k] = { total: 0, migrated: 0, not_migrated: 0, migration_percentage: 0 } }
    @kinds_stats = Hash.new { |h, k| h[k] = { total: 0, migrated: 0, not_migrated: 0, migration_percentage: 0, migrated_today: 0, migrated_week: 0, migrated_month: 0, last_migrated: nil } }
    
    stats_query = base_orders
      .select("
        kinds,
        COUNT(*) as total_count,
        COUNT(CASE WHEN shopify_order_id IS NOT NULL THEN 1 END) as migrated_count,
        COUNT(CASE WHEN DATE(tiny_creation_date) = '#{@today}' THEN 1 END) as today_total,
        COUNT(CASE WHEN DATE(tiny_creation_date) = '#{@today}' AND shopify_order_id IS NOT NULL THEN 1 END) as today_migrated,
        COUNT(CASE WHEN tiny_creation_date >= '#{@week_ago}' THEN 1 END) as week_total,
        COUNT(CASE WHEN tiny_creation_date >= '#{@week_ago}' AND shopify_order_id IS NOT NULL THEN 1 END) as week_migrated,
        COUNT(CASE WHEN tiny_creation_date >= '#{@month_ago}' THEN 1 END) as month_total,
        COUNT(CASE WHEN tiny_creation_date >= '#{@month_ago}' AND shopify_order_id IS NOT NULL THEN 1 END) as month_migrated
      ")
      .group(:kinds)
    
    last_migrated_query = base_orders
      .where.not(shopify_order_id: nil)
      .select("kinds, MAX(updated_at) as last_migrated")
      .group(:kinds)
      .index_by(&:kinds)
    
    stats_query.each do |stat|
      kind = stat.kinds
      
      @kinds_stats[kind][:total] = stat.total_count
      @kinds_stats[kind][:migrated] = stat.migrated_count
      @kinds_stats[kind][:not_migrated] = stat.total_count - stat.migrated_count
      @kinds_stats[kind][:migration_percentage] = stat.total_count > 0 ? (stat.migrated_count.to_f / stat.total_count * 100).round : 0
      @kinds_stats[kind][:migrated_today] = stat.today_migrated
      @kinds_stats[kind][:migrated_week] = stat.week_migrated
      @kinds_stats[kind][:migrated_month] = stat.month_migrated
      @kinds_stats[kind][:last_migrated] = last_migrated_query[kind]&.last_migrated if last_migrated_query[kind]
      
      @today_stats[kind][:total] = stat.today_total
      @today_stats[kind][:migrated] = stat.today_migrated
      @today_stats[kind][:not_migrated] = stat.today_total - stat.today_migrated
      @today_stats[kind][:migration_percentage] = stat.today_total > 0 ? (stat.today_migrated.to_f / stat.today_total * 100).round : 0
      
      @week_stats[kind][:total] = stat.week_total
      @week_stats[kind][:migrated] = stat.week_migrated
      @week_stats[kind][:not_migrated] = stat.week_total - stat.week_migrated
      @week_stats[kind][:migration_percentage] = stat.week_total > 0 ? (stat.week_migrated.to_f / stat.week_total * 100).round : 0
      
      @month_stats[kind][:total] = stat.month_total
      @month_stats[kind][:migrated] = stat.month_migrated
      @month_stats[kind][:not_migrated] = stat.month_total - stat.month_migrated
      @month_stats[kind][:migration_percentage] = stat.month_total > 0 ? (stat.month_migrated.to_f / stat.month_total * 100).round : 0
    end
    
    total_stats_query = base_orders
      .select("
        COUNT(CASE WHEN DATE(tiny_creation_date) = '#{@today}' THEN 1 END) as today_total,
        COUNT(CASE WHEN DATE(tiny_creation_date) = '#{@today}' AND shopify_order_id IS NOT NULL THEN 1 END) as today_migrated,
        COUNT(CASE WHEN tiny_creation_date >= '#{@week_ago}' THEN 1 END) as week_total,
        COUNT(CASE WHEN tiny_creation_date >= '#{@week_ago}' AND shopify_order_id IS NOT NULL THEN 1 END) as week_migrated,
        COUNT(CASE WHEN tiny_creation_date >= '#{@month_ago}' THEN 1 END) as month_total,
        COUNT(CASE WHEN tiny_creation_date >= '#{@month_ago}' AND shopify_order_id IS NOT NULL THEN 1 END) as month_migrated
      ")
      .first
    
    @today_stats['total'][:total] = total_stats_query.today_total
    @today_stats['total'][:migrated] = total_stats_query.today_migrated
    @today_stats['total'][:not_migrated] = total_stats_query.today_total - total_stats_query.today_migrated
    @today_stats['total'][:migration_percentage] = total_stats_query.today_total > 0 ? (total_stats_query.today_migrated.to_f / total_stats_query.today_total * 100).round : 0
    
    @week_stats['total'][:total] = total_stats_query.week_total
    @week_stats['total'][:migrated] = total_stats_query.week_migrated
    @week_stats['total'][:not_migrated] = total_stats_query.week_total - total_stats_query.week_migrated
    @week_stats['total'][:migration_percentage] = total_stats_query.week_total > 0 ? (total_stats_query.week_migrated.to_f / total_stats_query.week_total * 100).round : 0
    
    @month_stats['total'][:total] = total_stats_query.month_total
    @month_stats['total'][:migrated] = total_stats_query.month_migrated
    @month_stats['total'][:not_migrated] = total_stats_query.month_total - total_stats_query.month_migrated
    @month_stats['total'][:migration_percentage] = total_stats_query.month_total > 0 ? (total_stats_query.month_migrated.to_f / total_stats_query.month_total * 100).round : 0
  end
  
  def prepare_chart_data
    @daily_migration_data = get_daily_migration_data

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
    date_range = (@month_ago..@today)
    formatted_dates = date_range.map { |date| date.strftime('%d/%m') }

    daily_data = Order
      .select("
        kinds,
        DATE(tiny_creation_date) as migration_date,
        COUNT(CASE WHEN shopify_order_id IS NOT NULL THEN 1 END) as migrated_count
      ")
      .where(tiny_creation_date: @month_ago.beginning_of_day..@today.end_of_day)
      .group(:kinds, 'DATE(tiny_creation_date)')
      .order('DATE(tiny_creation_date)')

    data_by_kind_and_date = {}
    @kinds.each do |kind|
      data_by_kind_and_date[kind] = {}
      date_range.each do |date|
        data_by_kind_and_date[kind][date.strftime('%d/%m')] = 0
      end
    end

    daily_data.each do |data|
      formatted_date = data.migration_date.strftime('%d/%m')
      data_by_kind_and_date[data.kinds][formatted_date] = data.migrated_count if data_by_kind_and_date[data.kinds]
    end

    series = @kinds.map do |kind|
      {
        name: kind_display_name(kind),
        data: formatted_dates.map { |date| data_by_kind_and_date[kind][date] || 0 }
      }
    end

    {
      dates: formatted_dates,
      series:
    }
  end

  def load_recent_migrated_orders
    @recent_migrated_orders = {}

    @kinds.each do |kind|
      @recent_migrated_orders[kind] = Order.where(kinds: kind)
                                           .where.not(shopify_order_id: nil)
                                           .includes(:order_items)
                                           .order(tiny_creation_date: :desc)
                                           .limit(5)
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
