class Profile < ApplicationRecord
  has_many :user_profiles, dependent: :destroy
  has_many :users, through: :user_profiles
  has_many :screen_permissions, dependent: :destroy, autosave: true
  has_many :profile_ticket_sectors, dependent: :destroy
  has_many :ticket_sectors, through: :profile_ticket_sectors

  validates :name, presence: true
  validate :allowed_locations_exist

  before_validation :clean_allowed_locations

  ADMIN = 1
  MANAGER = 2
  USER = 3
  ADMIN_MARKETING = 5
  AGENT_MARKETING = 6

  def admin?
    id == ADMIN
  end

  def marketing_profile?
    [ADMIN_MARKETING, AGENT_MARKETING].include?(id)
  end

  def can_access?(screen_key)
    can?(screen_key, 'V')
  end

  # As ações de base de uma tela (abrir e responder chamados) valem para todo perfil.
  def can?(screen_key, action = 'V')
    return true if admin?

    "#{Screen.base_actions(screen_key)}#{actions_for(screen_key)}".include?(action.to_s.upcase)
  end

  def actions_for(screen_key)
    permissions_by_key[screen_key.to_s].to_s
  end

  def screen_keys
    screen_permissions.map(&:screen_key)
  end

  # Libera as telas por inteiro (todas as ações que cada uma oferece).
  def screen_keys=(keys)
    clean = Array(keys).reject(&:blank?) & Screen.keys
    self.screen_actions = clean.index_with { |key| Screen.acts(key) }
  end

  # { 'orders' => 'VP', 'b2b_orders' => 'VCE' }: telas fora do hash (ou sem ação) saem do perfil.
  def screen_actions=(map)
    map = (map.respond_to?(:to_unsafe_h) ? map.to_unsafe_h : map.to_h).transform_keys(&:to_s)
    wanted = map.slice(*Screen.keys)
                .transform_values { |letters| letters.is_a?(Array) ? letters.join : letters.to_s }
                .to_h { |key, letters| [key, Screen.normalize_actions(key, letters)] }
                .reject { |_, letters| letters.blank? }

    self.screen_permissions = wanted.map do |key, letters|
      screen_permissions.find_or_initialize_by(screen_key: key).tap { |p| p.actions = letters }
    end
    @permissions_by_key = nil
  end

  def location_keys
    Array(allowed_locations).map(&:to_s)
  end

  private

  def permissions_by_key
    @permissions_by_key ||= screen_permissions.to_h { |p| [p.screen_key, p.actions] }
  end

  def clean_allowed_locations
    self.allowed_locations = location_keys.reject(&:blank?).uniq
  end

  def allowed_locations_exist
    invalid = location_keys - User::AVAILABLE_LOCATIONS.keys
    errors.add(:allowed_locations, "contém lojas inválidas: #{invalid.join(', ')}") if invalid.any?
  end
end
