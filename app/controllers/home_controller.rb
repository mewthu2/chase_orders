class HomeController < ApplicationController
  before_action :authenticate_user!

  def index
    return unless current_user&.admin?
  end
end