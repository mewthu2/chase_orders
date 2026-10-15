class ImpersonationsController < ApplicationController
  before_action :super_admin_only!, only: :create

  def create
    target = User.find_by(email: params[:email].to_s.strip.downcase)
    return redirect_back fallback_location: root_path, alert: 'Nenhum usuário com esse e-mail.' unless target
    if target == true_user
      return impersonating? ? stop_impersonating : redirect_back(fallback_location: root_path, alert: 'Esse já é o seu usuário.')
    end

    impersonator = true_user
    bypass_sign_in(target, scope: :user)
    session[:impersonator_id] = impersonator.id
    log(impersonator, 'impersonate', target)
    redirect_to root_path, notice: "Você está logado como #{target.name}."
  end

  def destroy
    return redirect_to root_path unless impersonating?

    stop_impersonating
  end

  private

  def super_admin_only!
    redirect_to root_path, alert: 'Acesso negado.' unless true_user&.super_admin?
  end

  def stop_impersonating
    impersonator = true_user
    target = current_user
    session.delete(:impersonator_id)
    bypass_sign_in(impersonator, scope: :user)
    log(impersonator, 'stop_impersonating', target)
    redirect_to root_path, notice: 'Você voltou para o seu usuário.'
  end

  def log(impersonator, action, target)
    LogService.create_log(user: impersonator, resource_type: 'user', action_type: action,
                          resource_name: target.email, resource_id: target.id, request: request)
  end
end
