class CashbackUnification < ApplicationRecord
  belongs_to :user
  belongs_to :customer
  has_many :sources, class_name: 'CashbackUnificationSource', dependent: :restrict_with_exception

  enum :status, { draft: 'draft', processing: 'processing', completed: 'completed', rejected: 'rejected', needs_review: 'needs_review' }, prefix: false

  validates :code, :customer_gid, :source_snapshots, :expires_at, presence: true
  validates :code, uniqueness: true
  validates :amount, :minimum_purchase, numericality: { greater_than: 0 }

  STATUS_LABELS = {
    'draft' => 'Aguardando confirmação', 'processing' => 'Em processamento',
    'completed' => 'Concluída', 'rejected' => 'Não realizada', 'needs_review' => 'Precisa de conferência'
  }.freeze

  def status_label = STATUS_LABELS.fetch(status)
  def source_codes = source_snapshots.map { |source| source.fetch('code') }
end
