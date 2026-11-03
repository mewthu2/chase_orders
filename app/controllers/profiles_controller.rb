class ProfilesController < ApplicationController
  before_action :admin_only!
  before_action :set_profile, only: [:edit, :update, :destroy]

  def index
    @profiles = Profile.left_joins(:users).select('profiles.*, COUNT(DISTINCT users.id) AS users_count')
                       .group('profiles.id').order(:name).includes(:screen_permissions)
  end

  def new
    @profile = Profile.new
  end

  def create
    @profile = Profile.new(profile_params)
    if @profile.save
      redirect_to profiles_path, notice: 'Perfil criado com sucesso.'
    else
      render :new
    end
  end

  def edit; end

  def update
    if @profile.update(profile_params)
      redirect_to profiles_path, notice: 'Perfil atualizado com sucesso.'
    else
      render :edit
    end
  end

  def destroy
    if @profile.users.any?
      redirect_to profiles_path, alert: 'Não é possível excluir um perfil com usuários vinculados.'
      return
    end

    @profile.destroy
    redirect_to profiles_path, notice: 'Perfil removido com sucesso.'
  end

  private

  def set_profile
    @profile = Profile.find(params[:id])
  end

  # screen_actions: { 'b2b_orders' => ['V', 'C'] } vindo da matriz de ações; screen_keys ainda
  # libera telas inteiras (usado por integrações e testes antigos).
  def profile_params
    permitted = params.require(:profile).permit(:name, :description, :active, screen_keys: [], ticket_sector_ids: [],
                                                allowed_locations: [], screen_actions: Screen.keys.index_with { [] })
    permitted[:allowed_locations] = permitted[:allowed_locations].reject(&:blank?) if permitted.key?(:allowed_locations)
    # Admin vê tudo e abre chamado para todos os setores (User#admin?, User#visible_ticket_sector_ids).
    @profile&.admin? ? permitted.except(:ticket_sector_ids, :screen_actions, :screen_keys, :allowed_locations) : permitted
  end
end
