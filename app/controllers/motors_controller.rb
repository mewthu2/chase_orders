class MotorsController < ApplicationController
  before_action :load_form_references, only: [:index]

  def index
    @motors = Motor.paginate(page: params[:page], per_page: params_per_page(params[:per_page]))
  end

  private

  def load_form_references; end
end
