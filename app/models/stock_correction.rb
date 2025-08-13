class StockCorrection < ApplicationRecord
  belongs_to :user, optional: true
  has_many :stock_correction_items, dependent: :destroy
  
  validates :location, presence: true
  validates :correction_date, presence: true
  validates :reason, presence: true
  
  enum status: { pending: 'pending', executed: 'executed' }
  enum integration_status: { 
    integration_pending: 'pending', 
    integration_completed: 'completed', 
    integration_error: 'error' 
  }, _prefix: true
  
  scope :active, -> { where(deleted_at: nil) }
  scope :recent, -> { order(created_at: :desc) }
  
  def soft_delete!
    update!(deleted_at: Time.current)
  end
  
  def start_integration!
    update!(
      integration_started_at: Time.current,
      integration_status: 'pending',
      integration_error: nil
    )
  end
  
  def complete_integration!
    update!(
      integration_status: 'completed',
      integration_error: nil
    )
  end
  
  def fail_integration!(error_message)
    update!(
      integration_status: 'error',
      integration_error: error_message
    )
  end
  
  def integration_pending?
    integration_status == 'pending'
  end
  
  def location_display_name
    case location
    when 'lagoa_seca'
      'Lagoa Seca'
    when 'bh_shopping'
      'BH Shopping'
    when 'rj'
      'Rio de Janeiro'
    else
      location.humanize
    end
  end
end
