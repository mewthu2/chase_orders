module Whatsapp
  class Connection < ApplicationRecord
    encrypts :webhook_token, :qr_data
    has_many :memberships, dependent: :restrict_with_exception
    has_many :users, through: :memberships
    has_many :contacts, dependent: :restrict_with_exception
    has_many :conversations, dependent: :restrict_with_exception
    has_many :messages, dependent: :restrict_with_exception
    has_many :events, dependent: :restrict_with_exception
    has_many :receipts, dependent: :restrict_with_exception
    validates :name, presence: true, length: { maximum: 80 }
    validates :provider, inclusion: { in: ['evolution'] }
    before_validation on: :create do
      self.instance_key ||= "honey-#{SecureRandom.hex(16)}"
      self.webhook_token ||= SecureRandom.hex(32)
    end

    def self.visible_to(user)
      return none unless user&.active? && user.can_access_screen?('whatsapp_attend')
      return all if user.admin?
      where(id: Membership.where(user_id: user.id).select(:connection_id))
    end

    def self.administrable_by?(user)
      user&.active? && user.can_access_screen?('whatsapp_manage')
    end

    def gateway = Providers::Evolution.new(self)
    def connected? = enabled? && state == 'connected'
    def current_qr = (qr_data if qr_expires_at&.future? && enabled? && state != 'connected')

    def request_control!(action)
      with_lock do
        self.enabled = action != 'disconnect'
        self.control_action = action == 'connect' && %w[connected connecting qr].include?(state) ? 'reconnect' : action
        self.control_version += 1
        self.state = action == 'disconnect' ? 'disconnecting' : 'connecting'
        self.qr_data = self.qr_expires_at = nil if action == 'disconnect'
        save!
      end
      ControlJob.perform_later(id, control_version)
    end
  end
end
