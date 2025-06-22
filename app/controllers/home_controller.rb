class HomeController < ApplicationController
  before_action :authenticate_user!

  def index
    return unless current_user&.admin?

    @kinds = ['rj', 'bh_shopping', 'lagoa_seca']
    @today = Date.today
    @week_ago = 7.days.ago.to_date
    @month_ago = 30.days.ago.to_date
    load_dashboard_data
    prepare_chart_data
    load_recent_migrated_orders
    calculate_real_daily_averages
  end

  private

  def load_dashboard_data
    base_orders = Order.all
    @total_orders = base_orders.count
    @total_migrated = base_orders.where.not(shopify_order_id: nil).count
    @total_not_migrated = @total_orders - @total_migrated
    @migration_percentage = @total_orders.positive? ? (@total_migrated.to_f / @total_orders * 100).round : 0
    @today_stats = Hash.new { |h, k| h[k] = { total: 0, migrated: 0, not_migrated: 0, migration_percentage: 0 } }
    @week_stats = Hash.new { |h, k| h[k] = { total: 0, migrated: 0, not_migrated: 0, migration_percentage: 0 } }
    @month_stats = Hash.new { |h, k| h[k] = { total: 0, migrated: 0, not_migrated: 0, migration_percentage: 0 } }
    @kinds_stats = Hash.new { |h, k| h[k] = { total: 0, migrated: 0, not_migrated: 0, migration_percentage: 0, migrated_today: 0, migrated_week: 0, migrated_month: 0, last_migrated: nil } }

    base_orders.each do |order|
      kind = order.kinds
      @kinds_stats[kind][:total] += 1
      if order.shopify_order_id.present?
        @kinds_stats[kind][:migrated] += 1
      else
        @kinds_stats[kind][:not_migrated] += 1
      end

      tiny_date = if order.tiny_creation_date.is_a?(String)
        begin
          Date.strptime(order.tiny_creation_date, '%d/%m/%Y')
        rescue
          nil
        end
      else
        order.tiny_creation_date.try(:to_date)
      end

      if tiny_date.present?
        if tiny_date == @today
          @today_stats[kind][:total] += 1
          @today_stats['total'][:total] += 1
          if order.shopify_order_id.present?
            @today_stats[kind][:migrated] += 1
            @today_stats['total'][:migrated] += 1
            @kinds_stats[kind][:migrated_today] += 1
          else
            @today_stats[kind][:not_migrated] += 1
            @today_stats['total'][:not_migrated] += 1
          end
        end

        if tiny_date >= @week_ago && tiny_date <= @today
          @week_stats[kind][:total] += 1
          @week_stats['total'][:total] += 1
          if order.shopify_order_id.present?
            @week_stats[kind][:migrated] += 1
            @week_stats['total'][:migrated] += 1
            @kinds_stats[kind][:migrated_week] += 1
          else
            @week_stats[kind][:not_migrated] += 1
            @week_stats['total'][:not_migrated] += 1
          end
        end

        if tiny_date >= @month_ago && tiny_date <= @today
          @month_stats[kind][:total] += 1
          @month_stats['total'][:total] += 1
          if order.shopify_order_id.present?
            @month_stats[kind][:migrated] += 1
            @month_stats['total'][:migrated] += 1
            @kinds_stats[kind][:migrated_month] += 1
          else
            @month_stats[kind][:not_migrated] += 1
            @month_stats['total'][:not_migrated] += 1
          end
        end
      end
    end

    @kinds.each do |kind|
      @kinds_stats[kind][:migration_percentage] = @kinds_stats[kind][:total].positive? ? (@kinds_stats[kind][:migrated].to_f / @kinds_stats[kind][:total] * 100).round : 0
      @today_stats[kind][:migration_percentage] = @today_stats[kind][:total].positive? ? (@today_stats[kind][:migrated].to_f / @today_stats[kind][:total] * 100).round : 0
      @week_stats[kind][:migration_percentage] = @week_stats[kind][:total].positive? ? (@week_stats[kind][:migrated].to_f / @week_stats[kind][:total] * 100).round : 0
      @month_stats[kind][:migration_percentage] = @month_stats[kind][:total].positive? ? (@month_stats[kind][:migrated].to_f / @month_stats[kind][:total] * 100).round : 0
    end

    @today_stats['total'][:migration_percentage] = @today_stats['total'][:total].positive? ? (@today_stats['total'][:migrated].to_f / @today_stats['total'][:total] * 100).round : 0
    @week_stats['total'][:migration_percentage] = @week_stats['total'][:total].positive? ? (@week_stats['total'][:migrated].to_f / @week_stats['total'][:total] * 100).round : 0
    @month_stats['total'][:migration_percentage] = @month_stats['total'][:total].positive? ? (@month_stats['total'][:migrated].to_f / @month_stats['total'][:total] * 100).round : 0

    @kinds.each do |kind|
      last_migrated = Order.where(kinds: kind).where.not(shopify_order_id: nil).order(updated_at: :desc).first
      @kinds_stats[kind][:last_migrated] = last_migrated.try(:updated_at)
    end
  end

  def calculate_real_daily_averages
    @real_daily_averages = {}
    @kinds.each do |kind|
      orders = Order.where(kinds: kind).where.not(tiny_creation_date: [nil, ''])
      if orders.any?
        dates = orders.map do |order|
          if order.tiny_creation_date.is_a?(String)
            begin
              Date.strptime(order.tiny_creation_date, '%d/%m/%Y')
            rescue
              nil
            end
          else
            order.tiny_creation_date.try(:to_date)
          end
        end.compact.sort

        if dates.any?
          first_date = dates.first
          last_date = dates.last
          days_span = (last_date - first_date).to_i + 1
          total_orders = orders.count
          daily_average = days_span.positive? ? (total_orders.to_f / days_span).round(1) : 0
          @real_daily_averages[kind] = {
            total_orders: total_orders,
            first_date: first_date,
            last_date: last_date,
            days_span: days_span,
            daily_average: daily_average
          }
        else
          @real_daily_averages[kind] = { total_orders: 0, first_date: nil, last_date: nil, days_span: 0, daily_average: 0 }
        end
      else
        @real_daily_averages[kind] = { total_orders: 0, first_date: nil, last_date: nil, days_span: 0, daily_average: 0 }
      end
    end
  end

  def prepare_chart_data
    @daily_migration_data = get_daily_migration_data
    @status_distribution_data = {
      labels: @kinds.map { |kind| kind_display_name(kind) },
      series: [
        { name: 'Migrados', data: @kinds.map { |kind| @kinds_stats[kind][:migrated] } },
        { name: 'Pendentes', data: @kinds.map { |kind| @kinds_stats[kind][:not_migrated] } }
      ]
    }
    @weekday_distribution_data = get_weekday_distribution_data
    @completion_forecast_data = calculate_completion_forecast
  end

  def get_weekday_distribution_data
    weekdays = ['Domingo', 'Segunda', 'Terça', 'Quarta', 'Quinta', 'Sexta', 'Sábado']
    data_by_kind = {}
    @kinds.each { |kind| data_by_kind[kind] = Array.new(7, 0) }
    orders = Order.where.not(tiny_creation_date: nil).select(:kinds, :tiny_creation_date)
    orders.each do |order|
      date = if order.tiny_creation_date.is_a?(String)
        begin
          Date.strptime(order.tiny_creation_date, '%d/%m/%Y')
        rescue
          next
        end
      else
        order.tiny_creation_date.to_date
      end
      wday = date.wday
      data_by_kind[order.kinds][wday] += 1 if data_by_kind[order.kinds]
    end
    series = @kinds.map { |kind| { name: kind_display_name(kind), data: data_by_kind[kind] } }
    { categories: weekdays, series: series }
  end

  def get_daily_migration_data
    date_range = (@month_ago..@today)
    formatted_dates = date_range.map do |date|
      { short: I18n.l(date, format: '%a, %d/%b'), full: I18n.l(date, format: '%d/%m'), date: date }
    end
    orders = Order.where.not(tiny_creation_date: nil).where.not(shopify_order_id: nil).select(:kinds, :tiny_creation_date, :shopify_order_id)
    data_by_kind_and_date = {}
    @kinds.each do |kind|
      data_by_kind_and_date[kind] = {}
      date_range.each { |date| data_by_kind_and_date[kind][date.strftime('%d/%m')] = 0 }
    end
    orders.each do |order|
      date = if order.tiny_creation_date.is_a?(String)
        begin
          Date.strptime(order.tiny_creation_date, '%d/%m/%Y')
        rescue
          next
        end
      else
        order.tiny_creation_date.to_date
      end
      if date >= @month_ago && date <= @today
        formatted_date = date.strftime('%d/%m')
        data_by_kind_and_date[order.kinds][formatted_date] += 1 if data_by_kind_and_date[order.kinds]
      end
    end
    series = @kinds.map { |kind| { name: kind_display_name(kind), data: formatted_dates.map { |date| data_by_kind_and_date[kind][date[:full]] || 0 } } }
    { dates: formatted_dates.map { |d| d[:short] }, full_dates: formatted_dates, series: series }
  end

  def calculate_completion_forecast
    daily_migration_rates = {}
    completion_days = {}
    @kinds.each do |kind|
      last_week_migrations = Order.where(kinds: kind).where.not(shopify_order_id: nil).where('updated_at >= ?', 7.days.ago).count
      daily_rate = last_week_migrations / 7.0
      daily_migration_rates[kind] = daily_rate.positive? ? daily_rate : 0.1
      remaining_orders = @kinds_stats[kind][:not_migrated]
      days_to_complete = (remaining_orders / daily_migration_rates[kind]).ceil
      completion_days[kind] = days_to_complete
    end
    {
      labels: @kinds.map { |kind| kind_display_name(kind) },
      series: [{ name: 'Dias estimados para conclusão', data: @kinds.map { |kind| completion_days[kind] } }],
      daily_rates: daily_migration_rates,
      completion_days: completion_days
    }
  end

  def load_recent_migrated_orders
    @recent_migrated_orders = {}
    @kinds.each do |kind|
      @recent_migrated_orders[kind] = Order.where(kinds: kind).where.not(shopify_order_id: nil).includes(:order_items).last(5)
    end
  end

  def kind_display_name(kind)
    case kind
    when 'rj' then 'Rio de Janeiro'
    when 'bh_shopping' then 'BH Shopping'
    when 'lagoa_seca' then 'Lagoa Seca'
    else kind.titleize
    end
  end
end