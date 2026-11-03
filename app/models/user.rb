class User < ApplicationRecord
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable, :trackable

  has_many :user_profiles, dependent: :destroy
  has_many :profiles, through: :user_profiles, after_add: :reset_permission_cache, after_remove: :reset_permission_cache
  has_one_attached :avatar

  AVATAR_CONTENT_TYPES = %w[image/jpeg image/png image/webp].freeze
  AVATAR_MAX_SIZE = 5.megabytes

  has_many :marketing_tasks, foreign_key: :user_id, dependent: :nullify
  has_many :campaign_users, dependent: :destroy
  has_many :marketing_campaigns, through: :campaign_users
  has_many :created_campaigns, class_name: 'MarketingCampaign', foreign_key: :created_by_id, dependent: :nullify

  # Zoom do sistema (%) escolhido pelo usuário; o layout aplica no <html>.
  FONT_SCALE_RANGE = (80..150).step(10).to_a.freeze

  AVAILABLE_LOCATIONS = {
    'lagoa_seca' => {
      name: 'Lagoa Seca',
      shopify_id: ENV.fetch('LOCATION_LAGOA_SECA')
    },
    'bh_shopping' => {
      name: 'BH Shopping', 
      shopify_id: ENV.fetch('LOCATION_BH_SHOPPING')
    },
    'rj' => {
      name: 'RJ - Barra Shopping',
      shopify_id: ENV.fetch('LOCATION_BARRA_SHOPPING')
    },
    'eldorado_sp' => {
      name: 'Eldorado SP',
      shopify_id: ENV.fetch('LOCATION_ELDORADO_SP')
    },
    'fortaleza_rio_mar' => {
      name: 'Fortaleza Rio Mar',
      shopify_id: ENV.fetch('LOCATION_FORTALEZA_RIO_MAR')
    },
    'porto_alegre_bourbon' => {
      name: 'Porto Alegre Bourbon',
      shopify_id: ENV.fetch('LOCATION_PORTO_ALEGRE_BOURBON')
    },
    'shopping_analia_franco' => {
      name: 'Shopping Anália Franco',
      shopify_id: ENV.fetch('LOCATION_SHOPPING_ANALIA_FRANCO')
    },
    'iguatemi_campinas' => {
      name: 'Iguatemi Campinas',
      shopify_id: ENV.fetch('LOCATION_IGUATEMI_CAMPINAS')
    }
  }.freeze

  # Validações
  validates :name, presence: true
  validate :must_have_at_least_one_profile
  validate :validate_allowed_locations_exist
  validate :avatar_is_acceptable

  scope :active, -> { where(active: true) }
  scope :admins, -> { joins(:profiles).where(profiles: { id: Profile::ADMIN }) }
  scope :managers, -> { joins(:profiles).where(profiles: { id: Profile::MANAGER }) }
  scope :users, -> { joins(:profiles).where(profiles: { id: Profile::USER }) }
  scope :admin_marketing, -> { joins(:profiles).where(profiles: { id: Profile::ADMIN_MARKETING }) }
  scope :agent_marketing, -> { joins(:profiles).where(profiles: { id: Profile::AGENT_MARKETING }) }
  scope :marketing_users, -> { joins(:profiles).where(profiles: { id: [Profile::ADMIN_MARKETING, Profile::AGENT_MARKETING] }).distinct }

  # Callbacks
  before_validation :set_default_profile, on: :create
  before_validation :set_default_allowed_locations, on: :create
  after_save :reset_permission_cache
  before_validation :clean_allowed_locations
  after_update :log_location_changes, if: :saved_change_to_allowed_locations?

  SUPER_ADMIN_EMAILS = %w[danielkbr89@gmail.com].freeze

  # Super admin pode logar como qualquer usuário (ImpersonationsController).
  # Conta desativada em Gerenciar Usuários não entra (e perde a sessão aberta).
  def active_for_authentication?
    super && active?
  end

  def inactive_message
    active? ? super : :account_disabled
  end

  def super_admin?
    SUPER_ADMIN_EMAILS.include?(email.to_s.downcase)
  end

  def admin?
    profile_ids.include?(Profile::ADMIN)
  end

  def manager?
    profile_ids.include?(Profile::MANAGER)
  end

  def regular_user?
    profile_ids.include?(Profile::USER)
  end

  def admin_marketing?
    profile_ids.include?(Profile::ADMIN_MARKETING)
  end

  def agent_marketing?
    profile_ids.include?(Profile::AGENT_MARKETING)
  end

  def marketing_user?
    (profile_ids & [Profile::ADMIN_MARKETING, Profile::AGENT_MARKETING]).any?
  end

  def ticket_notifications?
    active? && ticket_notifications_enabled? && email.present?
  end

  # Setores de chamados que o usuário enxerga: admin vê todos; os demais, os liberados nos seus perfis.
  def visible_ticket_sector_ids
    return TicketSector.pluck(:id) if admin?

    ProfileTicketSector.where(profile_id: profile_ids).distinct.pluck(:ticket_sector_id)
  end

  # Quem pode fazer a ação na tela, numa consulta só (admin ou algum perfil que libera).
  def self.with_screen_access(screen_key, action = 'V')
    return all if Screen.base_actions(screen_key).include?(action)

    granted = ScreenPermission.where(screen_key: screen_key.to_s).where('actions LIKE ?', "%#{action}%").select(:profile_id)
    where(id: UserProfile.where(profile_id: Profile::ADMIN).or(UserProfile.where(profile_id: granted)).select(:user_id))
  end

  def can_access_screen?(screen_key)
    can?(screen_key, 'V')
  end

  # Ação numa tela (letras de Screen::ACTIONS). Vários perfis somam o que cada um libera.
  def can?(screen_key, action = 'V')
    admin? || "#{Screen.base_actions(screen_key)}#{permission_letters[screen_key.to_s]}".include?(action.to_s.upcase)
  end

  # Letras liberadas na tela, somando todos os perfis ("VCE").
  def actions_for(screen_key)
    return Screen.acts(screen_key) if admin?

    letters = "#{permission_letters[screen_key.to_s]}#{Screen.base_actions(screen_key)}".chars
    (Screen::ACTION_LETTERS & letters).join
  end

  def reload(*)
    @permission_letters = nil
    super
  end

  def profile_names
    profiles.pluck(:name).join(', ')
  end

  def profile_name
    return 'Sem Perfil' if profiles.empty?

    priority_order = [Profile::ADMIN, Profile::ADMIN_MARKETING, Profile::MANAGER, Profile::AGENT_MARKETING, Profile::USER]

    priority_profile_id = (profile_ids & priority_order).min_by { |id| priority_order.index(id) }

    case priority_profile_id
    when Profile::ADMIN
      'Administrador'
    when Profile::MANAGER
      'Gerente'
    when Profile::USER
      'Usuário'
    when Profile::ADMIN_MARKETING
      'Admin Marketing'
    when Profile::AGENT_MARKETING
      'Agente Marketing'
    else
      'Indefinido'
    end
  end

  def profile_ids
    profiles.loaded? ? profiles.map(&:id) : profiles.pluck(:id)
  end

  def profile?(profile_id)
    profile_ids.include?(profile_id)
  end

  def add_profile(profile_id)
    return if profile?(profile_id)
    profiles << Profile.find(profile_id)
  end

  def remove_profile(profile_id)
    profiles.delete(Profile.find(profile_id))
  end

  # Lojas do próprio usuário somadas às lojas liberadas nos seus perfis.
  def allowed_location_keys
    return AVAILABLE_LOCATIONS.keys if admin?

    keys = own_location_keys | profiles.flat_map(&:location_keys)
    AVAILABLE_LOCATIONS.keys & keys
  end

  def own_location_keys
    locations = allowed_locations
    return [] if locations.nil?

    case locations
    when Array
      locations.map(&:to_s)
    when String
      begin
        JSON.parse(locations).map(&:to_s)
      rescue JSON::ParserError
        []
      end
    else
      []
    end
  end

  def can_access_location?(location_key)
    return true if admin?

    allowed_location_keys.include?(location_key.to_s)
  end

  def available_locations_for_user
    if admin?
      AVAILABLE_LOCATIONS.map { |key, data| [data[:name], key] }
    else
      allowed_location_keys.map do |key|
        location_data = AVAILABLE_LOCATIONS[key]
        location_data ? [location_data[:name], key] : nil
      end.compact
    end
  end

  def set_allowed_locations(location_keys)
    clean_keys = location_keys.is_a?(Array) ? location_keys.reject(&:blank?) : []
    self.allowed_locations = clean_keys
  end

  def allowed_locations_names
    return ['Todas (Admin)'] if admin?
    return ['Nenhuma'] if allowed_location_keys.empty?

    allowed_location_keys.map do |key|
      AVAILABLE_LOCATIONS[key]&.dig(:name)
    end.compact
  end

  def location_access?
    admin? || allowed_location_keys.any?
  end

  def can_access_inventory?
    location_access?
  end

  def default_location
    return AVAILABLE_LOCATIONS.keys.first if admin?

    allowed_location_keys.first
  end

  def access_stats
    {
      total_locations: admin? ? AVAILABLE_LOCATIONS.count : allowed_location_keys.count,
      accessible_locations: allowed_locations_names,
      profile: profile_name,
      can_manage_users: admin?,
      can_manage_locations: admin?,
      can_access_inventory: can_access_inventory?
    }
  end

  def self.location_info(key)
    AVAILABLE_LOCATIONS[key.to_s]
  end

  def self.location_name(key)
    location_info(key)&.dig(:name) || key.to_s.humanize
  end

  def self.location_shopify_id(key)
    location_info(key)&.dig(:shopify_id)
  end

  def self.all_locations_for_select
    AVAILABLE_LOCATIONS.map { |key, data| [data[:name], key] }
  end

  private

  # { 'orders' => 'VPVC' }: letras liberadas em cada tela, somando os perfis. Uma consulta só, sem
  # carregar os perfis com as permissões (perfil admin nem precisaria delas).
  def permission_letters
    @permission_letters ||= ScreenPermission.where(profile_id: profile_ids).pluck(:screen_key, :actions)
                                            .each_with_object(Hash.new('')) { |(key, letters), map| map[key] += letters.to_s }
  end

  def reset_permission_cache(*)
    @permission_letters = nil
  end

  def avatar_is_acceptable
    return unless avatar.attached?

    unless AVATAR_CONTENT_TYPES.include?(avatar.blob.content_type)
      errors.add(:avatar, 'deve ser uma imagem JPG, PNG ou WEBP')
    end
    if avatar.blob.byte_size > AVATAR_MAX_SIZE
      errors.add(:avatar, 'deve ter no máximo 5 MB')
    end
  end

  def set_default_profile
    profiles << Profile.find(Profile::USER) if profiles.empty?
  end

  def must_have_at_least_one_profile
    errors.add(:profiles, 'deve ter pelo menos um perfil') if profiles.empty? && !new_record?
  end

  def set_default_allowed_locations
    self.allowed_locations ||= []
  end

  def clean_allowed_locations
    return if admin?

    case allowed_locations
    when Array
      self.allowed_locations = allowed_locations.reject(&:blank?).uniq
    when String
      begin
        parsed = JSON.parse(allowed_locations)
        self.allowed_locations = parsed.is_a?(Array) ? parsed.reject(&:blank?).uniq : []
      rescue JSON::ParserError
        self.allowed_locations = []
      end
    when nil
      self.allowed_locations = []
    else
      self.allowed_locations = []
    end
  end

  def validate_allowed_locations_exist
    return if admin?

    current_locations = allowed_location_keys
    return if current_locations.empty?

    invalid_locations = current_locations - AVAILABLE_LOCATIONS.keys

    errors.add(:allowed_locations, "contém locations inválidas: #{invalid_locations.join(', ')}") if invalid_locations.any?
  end

  def log_location_changes
    Rails.logger.info "User #{id} (#{name}) location permissions changed:"
    Rails.logger.info "Previous: #{allowed_locations_before_last_save}"
    Rails.logger.info "Current: #{allowed_locations}"
  end
end
