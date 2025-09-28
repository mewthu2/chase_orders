class MotorsController < ApplicationController
  def index
    @motors = Motor.all
    
    @motors = @motors.where('job_name ILIKE ?', "%#{params[:search]}%") if params[:search].present?

    case params[:status]
    when 'completed'
      @motors = @motors.where.not(end_time: nil)
    when 'running'
      @motors = @motors.where(end_time: nil)
    end

    @motors = @motors.order(start_time: :desc)

    @motors = @motors.paginate(page: params[:page], per_page: 10)
  end
end
