class StockCorrection < ApplicationRecord
  has_many :stock_correction_items, dependent: :destroy
  
  validates :location, presence: true
  validates :correction_date, presence: true
  validates :reason, presence: true
  
  # Soft delete scopes
  scope :active, -> { where(deleted_at: nil) }
  scope :deleted, -> { where.not(deleted_at: nil) }
  
  def soft_delete!
    update!(deleted_at: Time.current)
  end
  
  def deleted?
    deleted_at.present?
  end
  
  def restore!
    update!(deleted_at: nil)
  end
  
  def pending_corrections_count
    stock_correction_items.where(needs_correction: true, executed: false).count
  end
  
  def executed_corrections_count
    stock_correction_items.where(needs_correction: true, executed: true).count
  end
  
  def total_corrections_count
    stock_correction_items.where(needs_correction: true).count
  end
  
  def synced_corrections_count
    stock_correction_items.where(needs_correction: true, shopify_sync_status: 'synced').count
  end
end
