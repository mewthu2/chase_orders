class User < ApplicationRecord
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable

  has_many :user_profiles, dependent: :destroy
  has_many :profiles, through: :user_profiles
  
  has_many :marketing_tasks, foreign_key: :user_id, dependent: :nullify
  has_many :campaign_users, dependent: :destroy
  has_many :marketing_campaigns, through: :campaign_users
  has_many :created_campaigns, class_name: 'MarketingCampaign', foreign_key: :created_by_id, dependent: :nullify

  # Constante com as locations disponíveis
  AVAILABLE_LOCATIONS = {
    'lagoa_seca' => {
      name: 'Lagoa Seca',
      shopify_id: ENV.fetch('LOCATION_LAGOA_SECA', '72286994506')
    },
    'bh_shopping' => {
      name: 'BH Shopping', 
      shopify_id: ENV.fetch('LOCATION_BH_SHOPPING', '72286699594')
    },
    'rj' => {
      name: 'RJ - Barra Shopping',
      shopify_id: ENV.fetch('LOCATION_BARRA_SHOPPING', '72287027274')
    },
    'eldorado_sp' => {
      name: 'Eldorado SP',
      shopify_id: ENV.fetch('LOCATION_ELDORADO_SP', '74339975242')
    },
    'fortaleza_rio_mar' => {
      name: 'Fortaleza Rio Mar',
      shopify_id: ENV.fetch('LOCATION_FORTALEZA_RIO_MAR', '74208280650')
    },
    'porto_alegre_bourbon' => {
      name: 'Porto Alegre Bourbon',
      shopify_id: ENV.fetch('LOCATION_PORTO_ALEGRE_BOURBON', '74340008010')
    }
  }.freeze

  # Validações
  validates :name, presence: true
  validate :must_have_at_least_one_profile
  validate :validate_allowed_locations_exist

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
  before_validation :clean_allowed_locations
  after_update :log_location_changes, if: :saved_change_to_allowed_locations?

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

  def profile_names
    profiles.pluck(:name).join(', ')
  end

  def profile_name
    return 'Sem Perfil' if profiles.empty?
    
    # Prioridade: Admin > Admin Marketing > Manager > Agent Marketing > User
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
    profiles.pluck(:id)
  end

  def has_profile?(profile_id)
    profile_ids.include?(profile_id)
  end

  def add_profile(profile_id)
    return if has_profile?(profile_id)
    profiles << Profile.find(profile_id)
  end

  def remove_profile(profile_id)
    profiles.delete(Profile.find(profile_id))
  end

  def allowed_location_keys
    return AVAILABLE_LOCATIONS.keys if admin? # Admin tem acesso a todas
    
    locations = allowed_locations
    return [] if locations.nil?
    
    # Garantir que seja um array de strings
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
    return true if admin? # Admin tem acesso a todas
    
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

  def has_location_access?
    admin? || allowed_location_keys.any?
  end

  def can_access_inventory?
    has_location_access?
  end

  def default_location
    return AVAILABLE_LOCATIONS.keys.first if admin?
    
    allowed_location_keys.first
  end

  # Método para verificar se o usuário pode acessar uma funcionalidade específica
  def can_access_feature?(feature)
    case feature
    when :user_management
      admin?
    when :location_management
      admin?
    when :stock_corrections
      has_location_access?
    when :inventory_control
      has_location_access?
    when :reports
      admin? || manager?
    when :marketing_campaigns_admin
      admin? || admin_marketing?
    when :marketing_tasks
      admin? || marketing_user?
    when :marketing_dashboard
      admin? || marketing_user?
    else
      false
    end
  end

  # Método para obter estatísticas do usuário
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

  # Método de classe para obter informações de uma location
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

  def set_default_profile
    profiles << Profile.find(Profile::USER) if profiles.empty?
  end

  def must_have_at_least_one_profile
    errors.add(:profiles, "deve ter pelo menos um perfil") if profiles.empty? && !new_record?
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
    
    if invalid_locations.any?
      errors.add(:allowed_locations, "contém locations inválidas: #{invalid_locations.join(', ')}")
    end
  end

  def log_location_changes
    Rails.logger.info "User #{id} (#{name}) location permissions changed:"
    Rails.logger.info "  Previous: #{allowed_locations_before_last_save}"
    Rails.logger.info "  Current: #{allowed_locations}"
  end
end
