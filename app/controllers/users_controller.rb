class UsersController < ApplicationController
  before_action :authenticate_user!
  before_action :set_user, only: [:show, :edit, :update, :destroy]
  guard_screen :users_management, except: [:edit, :update]
  before_action :check_user_permission, only: [:edit, :update]

  def index
    @page = params[:page].to_i
    @page = 1 if @page < 1
    @per_page = 10
    @offset = (@page - 1) * @per_page
    @users = User.includes(:profiles).with_attached_avatar.limit(@per_page).offset(@offset).order(:name)
    @total_users = User.count
    @total_pages = (@total_users.to_f / @per_page).ceil
  end

  def show; end

  def new
    @user = User.new
  end

  def create
    @user = User.new(admin_user_params.except(:remove_avatar))

    validation = current_user.admin? && params[:user][:allowed_location_keys].present?
    @user.set_allowed_locations(params[:user][:allowed_location_keys]) if validation

    if @user.save
      redirect_to users_path, notice: 'Usuário criado com sucesso.'
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if !current_user.admin? && @user != current_user
      redirect_to root_path, alert: 'Acesso negado.'
      return
    end

    permitted_params = current_user.admin? ? admin_user_params : user_self_params
    remove_avatar = ActiveModel::Type::Boolean.new.cast(permitted_params.delete(:remove_avatar))
    permitted_params.delete(:avatar) if permitted_params[:avatar].blank?

    validation = current_user.admin? && @user != current_user && params[:user][:allowed_location_keys].present?
    @user.set_allowed_locations(params[:user][:allowed_location_keys]) if validation

    if permitted_params[:password].blank?
      permitted_params.delete(:password)
      permitted_params.delete(:password_confirmation)
    end

    unless current_user.admin?
      permitted_params.delete(:profile_ids)
      permitted_params.delete(:active)
    end

    if @user.update(permitted_params)
      @user.avatar.purge_later if remove_avatar && permitted_params[:avatar].blank?
      redirect_path = current_user.admin? ? users_path : root_path
      redirect_to redirect_path, notice: 'Usuário atualizado com sucesso.'
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @user.destroy
    redirect_to users_path, notice: 'Usuário removido com sucesso.'
  end

  private

  def set_user
    @user = User.includes(:profiles).find(params[:id])
  end

  def check_user_permission
    unless current_user.admin? || @user == current_user
      redirect_to root_path, alert: 'Acesso negado.'
    end
  end

  def admin_user_params
    params.require(:user).permit(:name, :email, :phone, :password, :password_confirmation, :active, :ticket_notifications_enabled, :avatar, :remove_avatar, profile_ids: [])
  end

  def user_self_params
    params.require(:user).permit(:name, :email, :phone, :password, :password_confirmation, :avatar, :remove_avatar)
  end

  def user_params
    admin_user_params
  end
end
