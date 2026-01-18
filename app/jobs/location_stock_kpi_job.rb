# frozen_string_literal: true

class LocationStockKpiJob < ApplicationJob
  queue_as :default

  def perform(action)
    case action.to_sym
    when :recalculate_kpi
      recalculate_all_kpis
    when :initialize_locations
      initialize_all_locations
    else
      raise ArgumentError, "Unknown action: #{action}"
    end
  end

  private

  def recalculate_all_kpis
    Location.find_each do |location|
      recalculate_kpi_for(location)
    end
  end

  def initialize_all_locations
    Location.find_each do |location|
      location.update_columns(
        kpi_ratio: nil,
        kpi_updated_at: Time.current
      )
    end
  end

  def recalculate_kpi_for(location)
    result = StockCorrectionItem.joins(:stock_correction)
                                .where(stock_corrections: { location: location.slug })
                                .pluck(
                                  Arel.sql('COUNT(*)'),
                                  Arel.sql('SUM(CASE WHEN needs_correction = true THEN 1 ELSE 0 END)')
                                )
                                .first

    total, with_error = result.map(&:to_i)

    ratio =
      if total.zero?
        nil
      else
        ((total - with_error).to_f / total * 100).round(2)
      end

    location.update_columns(
      kpi_ratio: ratio,
      kpi_updated_at: Time.current
    )
  end
end
