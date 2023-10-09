class ApplicationController < ActionController::Base
  before_action :authenticate_user!
  protect_from_forgery with: :exception

  layout 'home/layouts/admin'

  def after_sign_in_path_for(resource)
    case resource
    when User
      user_session_path
    end
  end

  def after_sign_out_path_for(resource_or_scope)
    case resource_or_scope
    when User
      user_session_path
    end
  end

  # Audity changes by user
  def authenticated_user
    current_user.present? ? "#{current_user.login} - #{current_user.name}" : 'SYSTEM'
  end
end
