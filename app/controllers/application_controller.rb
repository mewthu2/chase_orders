class ApplicationController < ActionController::Base
  include Common

  before_action :authenticate_user!
  protect_from_forgery with: :exception

  layout 'layouts/application'
end
