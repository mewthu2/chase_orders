# Retirada de estoque: documento em que se escolhe, por location, quanto retirar de cada produto.
# Ao concluir, as quantidades são retiradas direto no Shopify (StockWithdrawalProcessor).
class StockWithdrawal < ApplicationRecord
  # Motivos aceitos pelo Shopify no ajuste de inventário; aparecem no histórico do inventário.
  REASONS = {
    'shrinkage' => 'Perda / quebra',
    'damaged' => 'Danificado',
    'correction' => 'Correção',
    'quality_control' => 'Controle de qualidade',
    'marketing' => 'Marketing',
    'other' => 'Outro'
  }.freeze

  # O Shopify só aceita uma lista fixa de motivos no ajuste de inventário e não tem "marketing";
  # o mais próximo é "promotion" (Promoção ou doação). O texto "marketing" fica na referência do histórico.
  SHOPIFY_REASONS = { 'marketing' => 'promotion' }.freeze

  STALE_PROCESSING_AFTER = 10.minutes

  STATUS_LABELS = {
    'draft' => 'Rascunho', 'processing' => 'Processando', 'completed' => 'Concluída', 'partially_failed' => 'Concluída com falhas',
    'partially_completed' => 'Parcialmente concluída', 'reverted' => 'Revertida'
  }.freeze

  belongs_to :user
  has_many :items, class_name: 'StockWithdrawalItem', dependent: :destroy, inverse_of: :stock_withdrawal, validate: false, autosave: true
  has_many :locations, -> { distinct }, through: :items

  enum :status, { draft: 0, processing: 1, completed: 2, partially_failed: 3, partially_completed: 4, reverted: 5 }

  validates :withdrawal_date, presence: true
  validates :reason, inclusion: { in: REASONS.keys }
  validate :must_have_items
  validate :items_are_valid

  scope :recent, -> { order(created_at: :desc) }

  # Rascunho e retirada com falhas podem ser editados. Na com falhas, só as linhas ainda não
  # retiradas mudam; as já retiradas (e data/motivo, já usados no Shopify) ficam travadas.
  def editable?
    draft? || partially_failed?
  end

  def header_locked?
    !draft?
  end

  def editable_items
    items.reject(&:locked?)
  end

  def locked_items
    items.select(&:locked?)
  end

  # Recalcula o status a partir das linhas. Linha com falha/pendente mantém "concluída com falhas"
  # (para não esconder o que falta retirar); sem pendências: tudo retirado = concluída; parte
  # revertida = parcialmente concluída; tudo revertido = revertida.
  def refresh_status!
    lines = items.reload.to_a
    new_status =
      if lines.any? { |line| line.pending? || line.failed? } then :partially_failed
      elsif lines.all?(&:done?) then :completed
      elsif lines.any?(&:done?) then :partially_completed
      else :reverted
      end

    attrs = { status: new_status }
    attrs[:completed_at] = Time.current if new_status == :completed && completed_at.nil?
    attrs[:completed_at] = nil if new_status == :partially_failed
    update!(attrs)
    self
  end

  # Só rascunho pode ser excluído. Depois de integrada com o Shopify a retirada fica como registro
  # e o caminho para desfazer é reverter as linhas (devolve o estoque), nunca excluir.
  def deletable?
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

  def shopify_reason
    SHOPIFY_REASONS.fetch(reason, reason)
  end

  # Referência gravada no histórico do inventário do Shopify (inclui o motivo do Honey).
  def reference_uri
    "honey://stock-withdrawal/#{id}?motivo=#{reason}"
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
