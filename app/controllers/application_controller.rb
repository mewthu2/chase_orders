class ApplicationController < ActionController::Base
  include Common

  before_action :authenticate_user!
  protect_from_forgery unless: -> { request.format.json? }

  layout 'layouts/application'

  def self.guard_screen(key, **options)
    before_action(**options) { authorize_screen!(key) }
  end

  private

  def admin_only!
    redirect_to root_path, alert: 'Acesso negado. Apenas administradores podem acessar esta funcionalidade.' unless current_user&.admin?
  end

  def admin_or_manager!
    redirect_to root_path, alert: 'Acesso negado.' unless current_user&.admin? || current_user&.manager?
  end

  def authorize_screen!(screen_key)
    return if current_user&.can_access_screen?(screen_key)
    redirect_to root_path, alert: 'Acesso negado.'
  end
end
