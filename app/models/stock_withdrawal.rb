# Retirada de estoque: documento em que se escolhe, por location, quanto retirar de cada produto.
# Ao concluir, as quantidades são retiradas direto no Shopify (StockWithdrawalProcessor).
class StockWithdrawal < ApplicationRecord
  # Motivos aceitos pelo Shopify no ajuste de inventário; aparecem no histórico do inventário.
  REASONS = {
    'shrinkage' => 'Perda / quebra',
    'damaged' => 'Danificado',
    'correction' => 'Correção',
    'quality_control' => 'Controle de qualidade',
    'other' => 'Outro'
  }.freeze

  STALE_PROCESSING_AFTER = 10.minutes

  STATUS_LABELS = {
    'draft' => 'Rascunho', 'processing' => 'Processando', 'completed' => 'Concluída', 'partially_failed' => 'Concluída com falhas'
  }.freeze

  belongs_to :user
  has_many :items, class_name: 'StockWithdrawalItem', dependent: :destroy, inverse_of: :stock_withdrawal, validate: false, autosave: true
  has_many :locations, -> { distinct }, through: :items

  enum :status, { draft: 0, processing: 1, completed: 2, partially_failed: 3 }

  validates :withdrawal_date, presence: true
  validates :reason, inclusion: { in: REASONS.keys }
  validate :must_have_items
  validate :items_are_valid

  scope :recent, -> { order(created_at: :desc) }

  def editable?
    draft?
  end

  # Concluir (ou tentar de novo as falhas) só vale para rascunho e para o que terminou com falhas.
  def processable?
    draft? || partially_failed? || stale_processing?
  end

  # Uma execução que caiu no meio ficaria "processando" para sempre; passados 10 min ela não bloqueia mais.
  def stale_processing?
    processing? && updated_at < STALE_PROCESSING_AFTER.ago
  end

  def total_quantity
    items.sum(&:quantity)
  end

  def reason_label
    REASONS[reason]
  end

  def status_label
    STATUS_LABELS[status]
  end

  # Referência gravada no histórico do inventário do Shopify.
  def reference_uri
    "honey://stock-withdrawal/#{id}"
  end

  private

  # Em vez do genérico "Items não é válido", mostra o motivo de cada linha inválida.
  def items_are_valid
    items.each do |item|
      next if item.marked_for_destruction? || item.valid?

      item.errors.full_messages.each { |message| errors.add(:base, message) }
    end
  end

  def must_have_items
    errors.add(:base, 'A retirada precisa ter pelo menos um item') if items.reject(&:marked_for_destruction?).empty?
  end
end
