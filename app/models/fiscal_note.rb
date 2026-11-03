# NF-e gerada pelo Honey: montada e assinada aqui e autorizada direto na SEFAZ (Nfe::Transmitter).
class FiscalNote < ApplicationRecord
  ACTIVE_STATUSES = %w[rascunho assinada autorizada].freeze
  # Notas que ainda podem ir (ou voltar) para a SEFAZ com o mesmo XML assinado.
  TRANSMITTABLE_STATUSES = %w[assinada erro].freeze
  STATUS_LABELS = {
    'rascunho' => 'Rascunho', 'assinada' => 'Assinada', 'autorizada' => 'Autorizada',
    'rejeitada' => 'Rejeitada', 'cancelada' => 'Cancelada', 'erro' => 'Erro'
  }.freeze

  # Finalidade da nota, pelo que ela está ligada (pedido do site, atacado, transferência) ou pela natureza
  # (devolução, complementar, ajuste). [rótulo, cor, explicação]
  PURPOSES = {
    'ecommerce' => ['Pedido do e-commerce', 'green', 'Nota de um pedido feito na loja virtual (Shopify).'],
    'atacado' => ['Atacado', 'blue', 'Nota de um pedido de atacado (B2B).'],
    'transferencia' => ['Transferência', 'purple', 'Mercadoria enviada de um estoque ou loja para outra.'],
    'devolucao' => ['Devolução', 'orange', 'Nota de devolução de mercadoria.'],
    'complementar' => ['Complementar', 'yellow', 'Complementa valores de uma nota já emitida.'],
    'ajuste' => ['Ajuste', 'yellow', 'Nota de ajuste.'],
    'avulsa' => ['Avulsa', 'gray', 'Nota sem pedido de origem.']
  }.freeze
  NATURE_PURPOSE_KEYS = { 2 => 'complementar', 3 => 'ajuste', 4 => 'devolucao' }.freeze

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

  # Mesma regra de #purpose, em SQL, para o filtro da lista.
  def self.with_purpose(key)
    normal = '(operation_natures.purpose IS NULL OR operation_natures.purpose = 1)'
    transfer = '(fiscal_notes.internal_transfer_shipment_id IS NOT NULL OR COALESCE(b2b_orders.kind, -1) IN (1, 2))'
    ecommerce = "(fiscal_notes.order_id IS NOT NULL OR COALESCE(fiscal_notes.shopify_order_name, '') <> '')"
    no_origin = "NOT #{transfer} AND NOT #{ecommerce} AND fiscal_notes.b2b_order_id IS NULL"
    nature_transfer = 'COALESCE(operation_natures.kind, -1) = 1'
    sql =
      case key.to_s
      when *NATURE_PURPOSE_KEYS.values then "operation_natures.purpose = #{NATURE_PURPOSE_KEYS.key(key.to_s)}"
      when 'transferencia' then "#{normal} AND (#{transfer} OR (#{no_origin} AND #{nature_transfer}))"
      when 'ecommerce' then "#{normal} AND NOT #{transfer} AND #{ecommerce}"
      when 'atacado' then "#{normal} AND NOT #{transfer} AND NOT #{ecommerce} AND fiscal_notes.b2b_order_id IS NOT NULL"
      when 'avulsa' then "#{normal} AND #{no_origin} AND NOT #{nature_transfer}"
      else return none
      end
    left_joins(:nature, :b2b_order).where(sql)
  end

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

  def purpose
    nature_key = NATURE_PURPOSE_KEYS[nature&.purpose]
    return nature_key if nature_key
    return 'transferencia' if internal_transfer_shipment_id.present? || b2b_order&.stock_transfer? || b2b_order&.b2c_transfer?
    return 'ecommerce' if order_id.present? || shopify_order_name.present?
    return 'atacado' if b2b_order_id.present?
    return 'transferencia' if nature&.transfer?

    'avulsa'
  end

  def purpose_label
    PURPOSES.dig(purpose, 0)
  end

  def environment_label
    producao? ? 'Produção' : 'Homologação'
  end
end
