class DashboardController < ApplicationController
  skip_before_action :authenticate_user!, only: [:dalila]
  before_action :load_form_references, only: [:index]
  protect_from_forgery except: :modal_test

  def dalila
  end

  def index
    start_date = Time.new - 1.month

    ids_to_reject = Attempt.select(:tiny_order_id)
                           .where(kinds: :create_note_tiny2, status: :success)
                           .where('created_at >= ?', start_date)
                           .map(&:to_s)

    @orders = Tiny::Orders.get_all_orders('tiny_3', 'Preparando Envio', '', start_date)

    @all_orders = @orders&.reject do |order|
      ids_to_reject.include?(order['pedido']['id'].to_s)
    end

    ids_to_reject_emitions = Attempt.select(:tiny_order_id)
                                    .where(kinds: :emission_invoice_tiny2, status: :success)
                                    .where('created_at >= ?', start_date)
                                    .map(&:to_s)

    @emitions = Attempt.where(kinds: :create_note_tiny2, status: :success)
                       .where('created_at >= ?', start_date)
                       .where.not(tiny_order_id: ids_to_reject_emitions)
  end

  def invoice_emition
    @invoice_emition = Attempt.where(kinds: :create_correios_order, status: 2)
                              .distinct(:order_correios_id)
                              .where.not(order_correios_id: Attempt.where(kinds: :emission_invoice, status: 2).pluck(:order_correios_id))
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

      active_days = stats[:by_month].sum { |_, month_stats| month_stats[:total].positive? ? 1 : 0 }
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

  private

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

  def load_form_references; end
end
