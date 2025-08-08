class StockCorrection < ApplicationRecord
  belongs_to :user, optional: true
  has_many :stock_correction_items, dependent: :destroy
  
  accepts_nested_attributes_for :stock_correction_items, 
                                allow_destroy: true,
                                reject_if: :all_blank
  
  validates :correction_date, presence: true
  validates :reason, presence: true
  validates :location, presence: true, inclusion: { in: %w[lagoa_seca bh_shopping rj] }
  validates :status, inclusion: { in: %w[pending executed partial] }
  validates :integration_status, inclusion: { in: %w[pending completed error] }, allow_blank: true
  
  # Soft delete scope
  scope :active, -> { where(deleted_at: nil) }
  scope :deleted, -> { where.not(deleted_at: nil) }
  
  scope :by_location, ->(location) { where(location: location) }
  scope :pending, -> { where(status: 'pending') }
  scope :executed, -> { where(status: 'executed') }
  
  def location_name
    case location
    when 'lagoa_seca'
      'Lagoa Seca'
    when 'bh_shopping'
      'BH Shopping'
    when 'rj'
      'RJ - Barra Shopping'
    else
      'Location não definida'
    end
  end
  
  def items_to_correct
    stock_correction_items.where(needs_correction: true)
  end
  
  def checked_items
    stock_correction_items.where(checked: true)
  end
  
  def pending_items
    stock_correction_items.where(executed: false, needs_correction: true)
  end
  
  def execute_corrections!
    return false if status == 'executed'
    
    executed_count = 0
    total_corrections = items_to_correct.count
    
    items_to_correct.each do |item|
      if item.execute_correction!
        executed_count += 1
      end
    end
    
    if executed_count == total_corrections
      update!(status: 'executed', executed_at: Time.current)
    elsif executed_count > 0
      update!(status: 'partial', executed_at: Time.current)
    end
    
    executed_count > 0
  end
  
  # Métodos para controle de integração
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
  
  def integration_completed?
    integration_status == 'completed'
  end
  
  def integration_failed?
    integration_status == 'error'
  end
  
  # Soft delete methods
  def soft_delete!
    update!(deleted_at: Time.current)
  end
  
  def deleted?
    deleted_at.present?
  end
  
  def restore!
    update!(deleted_at: nil)
  end
end
