class UsersController < ApplicationController
  before_action :authenticate_user!
  before_action :set_user, only: [:show, :edit, :update, :destroy, :toggle_status, :send_password_reset]
  guard_screen :users_management, except: [:edit, :update], actions: { toggle_status: :edit, send_password_reset: :edit }
  before_action :protect_admin_accounts, only: [:toggle_status, :send_password_reset, :destroy]
  before_action :check_user_permission, only: [:edit, :update]

  def index
    @users = User.includes(:profiles, avatar_attachment: :blob).order(:name)
    # Nomes dos setores de cada perfil numa consulta só (admin nem usa).
    @sector_names = ProfileTicketSector.joins(:ticket_sector).order('ticket_sectors.name')
                                       .pluck(:profile_id, 'ticket_sectors.name').group_by(&:first).transform_values { |rows| rows.map(&:last) }
  end

  def show; end

  def new
    @user = User.new
  end

  def create
    @user = User.new(admin_user_params.except(:remove_avatar))
    # Perfis decidem o que a pessoa acessa: só o administrador escolhe. Os demais criam como Usuário.
    @user.profile_ids = [Profile::USER] unless current_user.admin?

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

  # Desativado não consegue entrar; o histórico continua guardado.
  def toggle_status
    return redirect_to(users_path, alert: 'Para mudar a sua conta, use Meu Perfil.') if @user == current_user

    @user.update!(active: !@user.active)
    redirect_to users_path, notice: @user.active ? "#{@user.name} foi ativado. A pessoa já pode entrar de novo com a mesma senha." : "#{@user.name} foi desativado. O acesso foi bloqueado agora."
  end

  # Manda o e-mail do Devise com o link para criar uma senha nova; a atual vale até lá.
  def send_password_reset
    @user.send_reset_password_instructions
    redirect_to users_path, notice: "Link enviado. #{@user.name} vai receber o e-mail em instantes."
  end

  private

  # Só administrador mexe na conta de outro administrador.
  def protect_admin_accounts
    return if current_user.admin? || !@user.admin?

    redirect_to users_path, alert: 'Só um administrador pode mudar a conta de outro administrador.'
  end

  def set_user
    @user = User.find(params[:id])
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
