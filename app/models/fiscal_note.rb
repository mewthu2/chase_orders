# NF-e gerada pelo Honey. Nesta fase a nota chega no máximo a "assinada": ainda não
# há transmissão à SEFAZ.
class FiscalNote < ApplicationRecord
  ACTIVE_STATUSES = %w[rascunho assinada autorizada].freeze
  STATUS_LABELS = {
    'rascunho' => 'Rascunho', 'assinada' => 'Assinada', 'autorizada' => 'Autorizada',
    'rejeitada' => 'Rejeitada', 'cancelada' => 'Cancelada', 'erro' => 'Erro'
  }.freeze

  belongs_to :company
  belongs_to :b2b_order, optional: true
  has_one_attached :xml

  enum :status, { rascunho: 0, assinada: 1, autorizada: 2, rejeitada: 3, cancelada: 4, erro: 5 }
  enum :environment, { producao: 1, homologacao: 2 }

  validates :number, :series, presence: true
  validates :number, uniqueness: { scope: [:company_id, :series] }
  validates :access_key, format: { with: /\A\d{44}\z/, message: 'deve ter 44 dígitos' }, allow_blank: true

  scope :recent, -> { order(created_at: :desc) }
  scope :active_statuses, -> { where(status: ACTIVE_STATUSES) }

  def self.active_for?(order)
    active_statuses.exists?(b2b_order_id: order.id)
  end

  def xml_available?
    xml.attached?
  end

  def status_label
    STATUS_LABELS[status]
  end
end
