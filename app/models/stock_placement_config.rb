# Empresa emissora, natureza de operação e destinatário da nota de remessa de cada lado da colocação de
# estoque (Log02 e Log03). Destinatário padrão: o depósito do Correios Log+ em Contagem.
class StockPlacementConfig < ApplicationRecord
  belongs_to :company, optional: true
  belongs_to :operation_nature, optional: true

  validates :side, inclusion: { in: StockPlacement::SIDES.keys }, uniqueness: true

  def self.for(side) = find_or_initialize_by(side: side)

  def recipient_data = B2bSetting.normalize_recipient(recipient.presence || B2bSetting::REMESSA_DEFAULT_RECIPIENT)
  def ready? = company.present? && operation_nature.present?
end
