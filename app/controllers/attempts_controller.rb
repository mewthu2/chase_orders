class AttemptsController < ApplicationController
  before_action :load_form_references, only: [:index]
  protect_from_forgery except: :verify_attempts

  def index
    @attempts = Attempt.where(status: params[:status], kinds: 0)
                       .paginate(page: params[:page], per_page: params_per_page(params[:per_page]))
  end

  def send_xml
    @attempts = Attempt.where(status: params[:status], kinds: 1)
                       .paginate(page: params[:page], per_page: params_per_page(params[:per_page]))
  end

  def verify_attempts
    @attempts = Attempt.where(tiny_order_id: params[:tiny_order_id])
                       .paginate(page: params[:page], per_page: params_per_page(params[:per_page]))
  end

  private

  def load_form_references; end
end