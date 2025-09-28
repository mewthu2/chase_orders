class DashboardController < ApplicationController
  before_action :authenticate_user!
  before_action :admin_only!
  protect_from_forgery except: :modal_test

  def push_tracking
    tracked_ids = Attempt.where(kinds: :get_tracking, status: :success).pluck(:order_correios_id)

    latest_ids = Attempt.where(kinds: :send_xml, status: :success)
                        .where.not(order_correios_id: tracked_ids)
                        .select('MAX(id) AS id')
                        .group(:order_correios_id)

    Attempt.where(id: latest_ids.map(&:id))
  end

  def send_xml
    processed_ids = Attempt.where(kinds: :send_xml, status: 2, created_at: 30.days.ago..Time.current)
                           .pluck(:order_correios_id)

    @send_xml = Attempt.where(kinds: :create_correios_order, status: 2, created_at: 30.days.ago..Time.current)
                       .distinct(:order_correios_id)
                       .where.not(order_correios_id: processed_ids)

    @last_errors = {}
  end

  def invoice_emition
    successful_ids = Attempt.where(kinds: :emission_invoice, status: :success)
                            .pluck(:order_correios_id)
                            .compact
    @invoice_emition = Attempt.where(kinds: :create_correios_order, status: :success)
                              .where.not(order_correios_id: successful_ids)
                              .distinct(:order_correios_id)
  end

  def stockend
    response = Correios::Orders.get_stock(params[:item_code])
    if response.code == 200
      @stock = response
    else
      @stock = nil
    end
    json_response(@stock)
  end

  def tracking
    response = Correios::Orders.get_tracking(params[:tracking_number])
    if response.code == 200
      @tracking = response['rastreio']
    else
      @tracking = nil
    end
    json_response(@tracking)
  end

  def order_correios_create
    @orders_response = Tiny::Orders.get_orders_response('', 'preparando_envio', ENV.fetch('TOKEN_TINY3_PRODUCTION'), '', 4.weeks.ago.strftime('%d/%m/%Y'))
    @orders = @orders_response&.dig('pedidos') || []

    successfully_processed_ids = Attempt.where(
      kinds: :create_correios_order,
      status: :success,
      created_at: 1.month.ago..Time.current
    ).pluck(:tiny_order_id).map(&:to_s)

    @pending_orders = @orders.reject do |order_data|
      order_id = order_data['pedido']['id'].to_s
      successfully_processed_ids.include?(order_id)
    end

    pending_order_ids = @pending_orders.map { |order_data| order_data['pedido']['id'].to_s }

    relevant_attempts = Attempt.where(
      kinds: :create_correios_order,
      tiny_order_id: pending_order_ids,
      created_at: 1.month.ago..Time.current
    ).where.not(message: [nil, ''])
                               .order(:created_at)

    queue_attempts = []
    failed_attempts = []

    relevant_attempts.each do |attempt|
      case attempt.status
      when 'fail', 'processing'
        queue_attempts << attempt
      when 'error'
        failed_attempts << attempt if failed_attempts.size < 10
      end
    end

    @queue_positions = queue_attempts.each_with_index.to_h do |attempt, index|
      [
        attempt.tiny_order_id.to_s,
        {
          position: index + 1,
          status: attempt.status,
          created_at: attempt.created_at,
          updated_at: attempt.updated_at,
          message: attempt.message
        }
      ]
    end

    @failed_attempts = failed_attempts.sort_by(&:updated_at).reverse

    grouped_status = relevant_attempts.group_by(&:status)
    @attempts_summary = {
      total: relevant_attempts.count,
      fail: grouped_status['fail']&.size || 0,
      error: grouped_status['error']&.size || 0,
      success: grouped_status['success']&.size || 0,
      processing: grouped_status['processing']&.size || 0
    }

    @last_errors = {}
    relevant_attempts
      .select { |a| %w[fail error].include?(a.status) && a.message.present? }
      .group_by(&:tiny_order_id).each do |order_id, attempts|
        last = attempts.max_by(&:updated_at)
        @last_errors[order_id.to_s] = {
          message: last.message,
          status: last.status,
          updated_at: last.updated_at
        }
      end

    @stats = {
      total_orders: @orders.count,
      pending_orders: @pending_orders.count,
      in_queue: queue_attempts.count,
      successful: successfully_processed_ids.count,
      failed: failed_attempts.count,
      pending: queue_attempts.count { |a| a.status == 'fail' },
      processing: queue_attempts.count { |a| a.status == 'processing' }
    }
  end

  def order_correios_tracking
    @filter_params = {
      status: params[:status],
      period: params[:period],
      order_id: params[:order_id]
    }

    prepare_tracking_data_optimized(@filter_params)
  end

  def update_invoice_id
    tiny_order_id = params[:tiny_order_id]
    id_nota_fiscal = params[:id_nota_fiscal]

    if tiny_order_id.blank? || id_nota_fiscal.blank?
      redirect_to order_correios_tracking_dashboard_index_path, alert: 'Parâmetros obrigatórios não informados.'
      return
    end

    begin
      # Find all successful attempts for the given tiny_order_id
      attempts = Attempt.where(tiny_order_id: tiny_order_id, status: :success)
      
      if attempts.empty?
        redirect_to order_correios_tracking_dashboard_index_path, alert: "Nenhum attempt com status 'success' encontrado para o pedido #{tiny_order_id}."
        return
      end

      # Update the id_nota_fiscal for all found attempts
      updated_count = attempts.update_all(id_nota_fiscal: id_nota_fiscal)
      
      redirect_to order_correios_tracking_dashboard_index_path, 
                  notice: "ID da nota fiscal atualizado com sucesso! #{updated_count} attempt(s) foram atualizados para o pedido #{tiny_order_id}."
    rescue => e
      Rails.logger.error "Erro ao atualizar ID da nota fiscal: #{e.message}"
      redirect_to order_correios_tracking_dashboard_index_path, 
                  alert: "Erro ao atualizar ID da nota fiscal: #{e.message}"
    end
  end

  private

  def prepare_tracking_data_optimized(filters = {})
    base_conditions = []
    sql_params = {}

    if filters[:period].present?
      case filters[:period]
      when 'today'
        base_conditions << 'so.created_at >= :today_start'
        sql_params[:today_start] = Date.current.beginning_of_day
      when '7'
        base_conditions << 'so.created_at >= :week_start'
        sql_params[:week_start] = 7.days.ago
      when '30'
        base_conditions << 'so.created_at >= :month_start'
        sql_params[:month_start] = 30.days.ago
      when '90'
        base_conditions << 'so.created_at >= :quarter_start'
        sql_params[:quarter_start] = 90.days.ago
      end
    end

    if filters[:order_id].present?
      base_conditions << 'so.tiny_order_id = :order_id'
      sql_params[:order_id] = filters[:order_id]
    end

    # Não inclui "WHERE" aqui — usamos "WHERE 1=1" dentro das CTEs e da query principal
    conditions_sql = base_conditions.any? ? "AND #{base_conditions.join(' AND ')}" : ''

    sql = <<-SQL
      WITH successful_orders AS (
        SELECT tiny_order_id, order_correios_id, MAX(created_at) AS created_at
        FROM attempts
        WHERE kinds = 0 AND status = 2
        GROUP BY tiny_order_id, order_correios_id
      ),
      invoice_pending AS (
        SELECT so.tiny_order_id
        FROM successful_orders so
        WHERE 1=1
        #{conditions_sql}
        AND NOT EXISTS (
          SELECT 1 FROM attempts a
          WHERE a.order_correios_id = so.order_correios_id
            AND a.kinds = 1 AND a.status = 2
        )
      ),
      xml_pending AS (
        SELECT so.tiny_order_id
        FROM successful_orders so
        WHERE 1=1
        #{conditions_sql}
        AND EXISTS (
          SELECT 1 FROM attempts a
          WHERE a.order_correios_id = so.order_correios_id
            AND a.kinds = 1 AND a.status = 2
        )
        AND NOT EXISTS (
          SELECT 1 FROM attempts a
          WHERE a.order_correios_id = so.order_correios_id
            AND a.kinds = 2 AND a.status = 2
        )
      ),
      tracking_pending AS (
        SELECT so.tiny_order_id
        FROM successful_orders so
        WHERE 1=1
        #{conditions_sql}
        AND EXISTS (
          SELECT 1 FROM attempts a
          WHERE a.order_correios_id = so.order_correios_id
            AND a.kinds = 2 AND a.status = 2
        )
        AND NOT EXISTS (
          SELECT 1 FROM attempts a
          WHERE a.order_correios_id = so.order_correios_id
            AND a.kinds = 3 AND a.status = 2
        )
      )
      SELECT
        so.tiny_order_id,
        CASE
          WHEN ip.tiny_order_id IS NOT NULL THEN 'invoice_emition'
          WHEN xp.tiny_order_id IS NOT NULL THEN 'send_xml'
          WHEN tp.tiny_order_id IS NOT NULL THEN 'push_tracking'
          ELSE 'completed'
        END AS current_status
      FROM successful_orders so
      LEFT JOIN invoice_pending ip ON so.tiny_order_id = ip.tiny_order_id
      LEFT JOIN xml_pending xp ON so.tiny_order_id = xp.tiny_order_id
      LEFT JOIN tracking_pending tp ON so.tiny_order_id = tp.tiny_order_id
      WHERE 1=1
      #{conditions_sql}
      ORDER BY so.created_at DESC;
    SQL

    results = if sql_params.any?
      ActiveRecord::Base.connection.exec_query(
        ActiveRecord::Base.sanitize_sql_array([sql, sql_params])
      )
    else
      ActiveRecord::Base.connection.exec_query(sql)
    end

    @tracking_summary = {}
    invoice_count = 0
    xml_count = 0
    tracking_count = 0

    results.rows.each do |row|
      order_id = row[0].to_s
      status = row[1]

      next if filters[:status].present? && filters[:status] != status

      @tracking_summary[order_id] = {
        invoice_emition: status == 'invoice_emition',
        send_xml: status == 'send_xml',
        push_tracking: status == 'push_tracking'
      }

      case status
      when 'invoice_emition'
        invoice_count += 1
      when 'send_xml'
        xml_count += 1
      when 'push_tracking'
        tracking_count += 1
      end
    end

    @tracking_stats = {
      invoice_emition: invoice_count,
      send_xml: xml_count,
      push_tracking: tracking_count,
      total_tracking: @tracking_summary.count
    }
  end

  def ranking_sellers
    orders_with_sellers = Order.where.not(tags: [nil, ''])
    sellers_stats = Hash.new do |hash, key|
      hash[key] = {
        total: 0,
        migrated: 0,
        not_migrated: 0,
        by_kind: Hash.new { |h, k| h[k] = { total: 0, migrated: 0 } },
        by_month: Hash.new { |h, k| h[k] = { total: 0, migrated: 0 } },
        by_weekday: Array.new(7, 0)
      }
    end

    orders_with_sellers.each do |order|
      seller_name = order.tags.strip
      sellers_stats[seller_name][:total] += 1

      if order.shopify_order_id.present?
        sellers_stats[seller_name][:migrated] += 1
      else
        sellers_stats[seller_name][:not_migrated] += 1
      end

      sellers_stats[seller_name][:by_kind][order.kinds][:total] += 1
      sellers_stats[seller_name][:by_kind][order.kinds][:migrated] += 1 if order.shopify_order_id.present?

      date = if order.tiny_creation_date.is_a?(String)
        Date.strptime(order.tiny_creation_date, '%d/%m/%Y')
      else
        order.tiny_creation_date.try(:to_date)
      end

      next unless date.present?

      month_key = date.strftime('%Y-%m')
      sellers_stats[seller_name][:by_month][month_key][:total] += 1
      sellers_stats[seller_name][:by_month][month_key][:migrated] += 1 if order.shopify_order_id.present?

      wday = date.wday
      sellers_stats[seller_name][:by_weekday][wday] += 1
    end

    sellers_stats.each do |seller, stats|
      stats[:migration_percentage] = stats[:total].positive? ? (stats[:migrated].to_f / stats[:total] * 100).round : 0

      stats[:by_kind].each_value do |kind_stats|
        kind_stats[:migration_percentage] = kind_stats[:total].positive? ? (kind_stats[:migrated].to_f / kind_stats[:total] * 100).round : 0
      end

      stats[:by_month].each_value do |month_stats|
        month_stats[:migration_percentage] = month_stats[:total].positive? ? (month_stats[:migrated].to_f / month_stats[:total] * 100).round : 0
      end

      months = stats[:by_month].keys.sort.last(6)
      if months.length >= 6
        recent_months = months.last(3)
        previous_months = months.first(3)
        recent_total = recent_months.sum { |m| stats[:by_month][m][:total] }
        previous_total = previous_months.sum { |m| stats[:by_month][m][:total] }
        stats[:trend] = if previous_total.positive?
          ((recent_total.to_f / previous_total) - 1) * 100
        else
          0
        end
      else
        stats[:trend] = 0
      end

      stats[:best_weekday] = stats[:by_weekday].index(stats[:by_weekday].max)
      active_days = stats[:by_month].sum { |_, month_stats| stats[:total].positive? ? 1 : 0 }
      stats[:daily_average] = active_days.positive? ? (stats[:total].to_f / active_days).round(1) : 0
    end

    @sellers_ranking = sellers_stats.sort_by { |_, stats| -stats[:total] }
    @total_orders = @sellers_ranking.sum { |_, stats| stats[:total] }
    @total_migrated = @sellers_ranking.sum { |_, stats| stats[:migrated] }
    @total_not_migrated = @sellers_ranking.sum { |_, stats| stats[:not_migrated] }
    @migration_percentage = @total_orders.positive? ? (@total_migrated.to_f / @total_orders * 100).round : 0

    @context_stats = {}
    ['rj', 'bh_shopping', 'lagoa_seca'].each do |kind|
      @context_stats[kind] = {
        total: 0,
        migrated: 0,
        not_migrated: 0,
        sellers: 0,
        migration_percentage: 0
      }
    end

    ['rj', 'bh_shopping', 'lagoa_seca'].each do |kind|
      @sellers_ranking.each do |_, stats|
        if stats[:by_kind][kind] && stats[:by_kind][kind][:total].positive?
          @context_stats[kind][:total] += stats[:by_kind][kind][:total]
          @context_stats[kind][:migrated] += stats[:by_kind][kind][:migrated]
          @context_stats[kind][:not_migrated] += stats[:by_kind][kind][:total] - stats[:by_kind][kind][:migrated]
          @context_stats[kind][:sellers] += 1
        end
      end

      @context_stats[kind][:migration_percentage] = @context_stats[kind][:total].positive? ? 
        (@context_stats[kind][:migrated].to_f / @context_stats[kind][:total] * 100).round : 0
    end

    prepare_chart_data
  end

  def prepare_chart_data
    top_sellers = @sellers_ranking.first(10)

    @top_sellers_chart_data = {
      labels: top_sellers.map { |seller, _| seller },
      series: [
        {
          name: 'Migrados',
          data: top_sellers.map { |_, stats| stats[:migrated] }
        },
        {
          name: 'Pendentes',
          data: top_sellers.map { |_, stats| stats[:not_migrated] }
        }
      ]
    }

    @sellers_distribution_data = {
      labels: top_sellers.map { |seller, _| seller },
      series: top_sellers.map { |_, stats| stats[:total] }
    }

    @sellers_efficiency_data = {
      labels: top_sellers.map { |seller, _| seller },
      series: [
        {
          name: 'Taxa de Migração',
          data: top_sellers.map { |_, stats| stats[:migration_percentage] }
        }
      ]
    }

    @context_distribution_data = {
      labels: ['Rio de Janeiro', 'BH Shopping', 'Lagoa Seca'],
      series: [
        {
          name: 'Migrados',
          data: ['rj', 'bh_shopping', 'lagoa_seca'].map { |kind| @context_stats[kind][:migrated] }
        },
        {
          name: 'Pendentes',
          data: ['rj', 'bh_shopping', 'lagoa_seca'].map { |kind| @context_stats[kind][:not_migrated] }
        }
      ]
    }

    weekdays = ['Domingo', 'Segunda', 'Terça', 'Quarta', 'Quinta', 'Sexta', 'Sábado']
    top5_sellers = @sellers_ranking.first(5)

    @weekday_distribution_data = {
      categories: weekdays,
      series: top5_sellers.map do |seller, stats|
        {
          name: seller,
          data: stats[:by_weekday]
        }
      end
    }

    all_months = @sellers_ranking.flat_map { |_, stats| stats[:by_month].keys }.uniq.sort.last(12)
    formatted_months = all_months.map do |month|
      year, month_num = month.split('-')
      Date.new(year.to_i, month_num.to_i, 1).strftime('%b/%Y')
    end

    @monthly_trend_data = {
      categories: formatted_months,
      series: top5_sellers.map do |seller, stats|
        {
          name: seller,
          data: all_months.map { |month| stats[:by_month][month] ? stats[:by_month][month][:total] : 0 }
        }
      end
    }
  end

  def api_correios; end

  def admin_only!
    unless current_user&.admin?
      redirect_to root_path, alert: 'Acesso negado. Apenas administradores podem acessar esta funcionalidade.'
    end
  end
end
