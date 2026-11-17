# NF-e gerada pelo Honey: montada e assinada aqui e autorizada direto na SEFAZ (Nfe::Transmitter).
class FiscalNote < ApplicationRecord
  ACTIVE_STATUSES = %w[rascunho assinada autorizada].freeze
  # Notas que ainda podem ir (ou voltar) para a SEFAZ com o mesmo XML assinado.
  TRANSMITTABLE_STATUSES = %w[assinada erro].freeze
  STATUS_LABELS = {
    'rascunho' => 'Gerada, falta emitir', 'assinada' => 'Assinada', 'autorizada' => 'Autorizada',
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
  # Evento de cancelamento homologado na SEFAZ (procEventoNFe), gravado pelo Nfe::Canceller.
  has_one_attached :cancel_xml

  enum :status, { rascunho: 0, assinada: 1, autorizada: 2, rejeitada: 3, cancelada: 4, erro: 5 }
  enum :environment, { producao: 1, homologacao: 2 }

  validates :number, :series, presence: true
  validates :number, uniqueness: { scope: [:company_id, :environment, :series] }
  validates :access_key, format: { with: /\A\d{44}\z/, message: 'deve ter 44 dígitos' }, allow_blank: true

  scope :recent, -> { order(created_at: :desc) }
  scope :active_statuses, -> { where(status: ACTIVE_STATUSES) }
  # Papel da nota no pedido B2B: vazio é a nota do pedido (a que vai ao Correios); 'remessa' é a nota de
  # remessa do abastecimento (ex.: para o depósito do Correios), uma nota a mais.
  ROLES = %w[remessa].freeze
  validates :role, inclusion: { in: ROLES }, allow_nil: true
  scope :principal, -> { where(role: nil) }
  scope :remessas, -> { where(role: 'remessa') }

  def remessa?
    role == 'remessa'
  end

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

  # Prazo normal para cancelar pela SEFAZ. O Honey não bloqueia depois dele (homologação e produção): só avisa,
  # porque a SEFAZ pode recusar (501) ou aceitar como fora do prazo (155).
  CANCEL_WINDOW = 24.hours

  # Rascunho: gerada e assinada para conferir (DANFE/XML), sem ir à SEFAZ. Só sai com "Emitir na SEFAZ";
  # nenhuma rotina automática (Log02, envio da remessa) emite rascunho por conta própria.
  def emittable?
    rascunho? && xml_available?
  end

  # Gerar uma nota nova no lugar desta: depois do cancelamento, para o mesmo pedido ou remessa.
  def regenerable?
    cancelada? && (b2b_order_id.present? || internal_transfer_shipment_id.present? || order_id.present?)
  end

  # Cancelamento na SEFAZ (evento 110111): a nota autorizada, com chave e protocolo, a qualquer tempo.
  def cancelable?
    autorizada? && access_key.present? && protocol.present?
  end

  def within_cancel_window?
    authorized_at.present? && authorized_at > CANCEL_WINDOW.ago
  end

  def cancel_deadline
    authorized_at && authorized_at + CANCEL_WINDOW
  end

  def status_label
    STATUS_LABELS[status]
  end

  def denied?
    rejeitada? && Nfe::Transmitter::DENIED_CODES.include?(sefaz_status_code.to_s)
  end

  # Por que a nota não pode ser excluída do Honey (nil quando pode). Homologação não tem valor fiscal: sai
  # sempre. Em produção, a autorizada vale na SEFAZ (precisa ser cancelada lá, pela tela da nota), a
  # sem resposta pode ter sido autorizada e a denegada fica registrada com o número.
  def undeletable_reason
    return nil if homologacao?
    return 'A nota de produção autorizada vale na SEFAZ: cancele na SEFAZ (tela da nota) em vez de excluir.' if autorizada? || cancelada?
    return 'Esta nota ficou sem resposta da SEFAZ e pode ter sido autorizada. Consulte-a antes de excluir.' if erro?
    return 'A SEFAZ denegou esta nota: o número fica registrado e a nota não pode ser excluída.' if denied?

    nil
  end

  def deletable?
    undeletable_reason.nil?
  end

  # Exclui a nota. Se ela nunca valeu na SEFAZ e era a última do ambiente, o número volta para a próxima.
  def discard!
    reason = undeletable_reason
    raise ActiveRecord::RecordNotDestroyed.new(reason, self) if reason

    transaction do
      company.with_lock do
        company.release_nfe_number!(number, environment) if (rascunho? || assinada? || rejeitada?) && series == company.nfe_series
        destroy!
      end
    end
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

  # Última nota do pedido (não cancelada, sem as de remessa) de cada pedido B2B, preferindo a de produção: { b2b_order_id => { environment:, status:, number: } }.
  # order_ids pode ser uma lista ou um select de ids.
  def self.latest_by_order(order_ids)
    rows = principal.where(b2b_order_id: order_ids).where.not(status: :cancelada).order(:id).pluck(:b2b_order_id, :environment, :status, :number)
    rows.group_by(&:first).transform_values do |list|
      _, env, status, number = list.select { |r| r[1] == 'producao' }.last || list.last
      { environment: env, status: status, number: number }
    end
  end
end
