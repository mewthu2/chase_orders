class Motor < ApplicationRecord
  before_save :calculate_running_time, if: -> { end_time_changed? }

  def formatted_running_time
    return nil unless running_time

    hours = running_time / 3600
    minutes = (running_time % 3600) / 60
    seconds = running_time % 60

    format('%02d:%02d:%02d', hours, minutes, seconds)
  end

  private

  def calculate_running_time
    return unless start_time && end_time

    duration = end_time - start_time
    self.running_time = duration.to_i
  end
end
