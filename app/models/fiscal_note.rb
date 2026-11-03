# NF-e gerada pelo Honey: montada e assinada aqui e autorizada direto na SEFAZ (Nfe::Transmitter).
class FiscalNote < ApplicationRecord
  ACTIVE_STATUSES = %w[rascunho assinada autorizada].freeze
  # Notas que ainda podem ir (ou voltar) para a SEFAZ com o mesmo XML assinado.
  TRANSMITTABLE_STATUSES = %w[assinada erro].freeze
  STATUS_LABELS = {
    'rascunho' => 'Rascunho', 'assinada' => 'Assinada', 'autorizada' => 'Autorizada',
    'rejeitada' => 'Rejeitada', 'cancelada' => 'Cancelada', 'erro' => 'Erro'
  }.freeze

  belongs_to :company
  belongs_to :b2b_order, optional: true
  belongs_to :order, optional: true
  belongs_to :internal_transfer_shipment, optional: true
  belongs_to :nature, class_name: 'OperationNature', foreign_key: :operation_nature_id, optional: true
  has_one_attached :xml

  enum :status, { rascunho: 0, assinada: 1, autorizada: 2, rejeitada: 3, cancelada: 4, erro: 5 }
  enum :environment, { producao: 1, homologacao: 2 }

  validates :number, :series, presence: true
  validates :number, uniqueness: { scope: [:company_id, :environment, :series] }
  validates :access_key, format: { with: /\A\d{44}\z/, message: 'deve ter 44 dígitos' }, allow_blank: true

  scope :recent, -> { order(created_at: :desc) }
  scope :active_statuses, -> { where(status: ACTIVE_STATUSES) }

  def self.active_for?(order)
    column = order.is_a?(Order) ? :order_id : :b2b_order_id
    active_statuses.exists?(column => order.id)
  end

  def xml_available?
    xml.attached?
  end

  def transmittable?
    TRANSMITTABLE_STATUSES.include?(status) && xml_available?
  end

  # Erro de comunicação pode ter chegado à SEFAZ: vale consultar pela chave antes de reenviar.
  def consultable?
    access_key.present? && (erro? || assinada? || rejeitada?)
  end

  def status_label
    STATUS_LABELS[status]
  end

  def environment_label
    producao? ? 'Produção' : 'Homologação'
  end
end
