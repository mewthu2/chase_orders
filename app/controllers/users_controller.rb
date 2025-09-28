class UsersController < ApplicationController
  before_action :authenticate_user!
  before_action :set_user, only: [:show, :edit, :update, :destroy]
  before_action :admin_required, except: [:edit, :update]
  before_action :check_user_permission, only: [:edit, :update]

  def index
    @page = params[:page].to_i
    @page = 1 if @page < 1
    @per_page = 10
    @offset = (@page - 1) * @per_page
    @users = User.limit(@per_page).offset(@offset).order(:name)
    @total_users = User.count
    @total_pages = (@total_users.to_f / @per_page).ceil
  end

  def show; end

  def new
    @user = User.new
  end

  def create
    @user = User.new(admin_user_params)

    validation = current_user_admin? && params[:user][:allowed_location_keys].present?
    @user.set_allowed_locations(params[:user][:allowed_location_keys]) if validation

    if @user.save
      redirect_to users_path, notice: 'Usuário criado com sucesso.'
    else
      render :new
    end
  end

  def edit; end

  def update
    if !current_user_admin? && @user != current_user
      redirect_to root_path, alert: 'Acesso negado.'
      return
    end

    permitted_params = current_user_admin? ? admin_user_params : user_self_params

    validation = current_user_admin? && @user != current_user && params[:user][:allowed_location_keys].present?
    @user.set_allowed_locations(params[:user][:allowed_location_keys]) if validation

    if permitted_params[:password].blank?
      permitted_params.delete(:password)
      permitted_params.delete(:password_confirmation)
    end

    unless current_user_admin?
      permitted_params.delete(:profile_id)
      permitted_params.delete(:active)
    end

    if @user.update(permitted_params)
      redirect_path = current_user_admin? ? users_path : root_path
      redirect_to redirect_path, notice: 'Usuário atualizado com sucesso.'
    else
      render :edit
    end
  end

  def destroy
    @user.destroy
    redirect_to users_path, notice: 'Usuário removido com sucesso.'
  end

  private

  def set_user
    @user = User.find(params[:id])
  end

  def admin_required
    unless current_user_admin?
      redirect_to root_path, alert: 'Acesso negado.'
    end
  end

  def check_user_permission
    unless current_user_admin? || @user == current_user
      redirect_to root_path, alert: 'Acesso negado.'
    end
  end

  def current_user_admin?
    current_user&.profile_id == 1
  end

  def admin_user_params
    params.require(:user).permit(:name, :email, :phone, :password, :password_confirmation, :profile_id, :active)
  end

  def user_self_params
    params.require(:user).permit(:name, :email, :phone, :password, :password_confirmation)
  end

  def user_params
    admin_user_params
  end
end
