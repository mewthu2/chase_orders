module ScheduleUtils
  def self.within_schedule?
    now = Time.zone.now
    now.wday.between?(1, 5) && now.hour.between?(8, 21)
  end
end