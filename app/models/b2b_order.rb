class B2bOrder < ApplicationRecord
  belongs_to :client, optional: true
  belongs_to :transfer_location, optional: true
  belongs_to :carrier, optional: true
  belongs_to :user
  has_many :b2b_order_items, dependent: :destroy
  accepts_nested_attributes_for :b2b_order_items, allow_destroy: true, reject_if: :all_blank

  has_many :fiscal_notes, dependent: :nullify

  enum :kind, { sale: 0, stock_transfer: 1 }
  enum :status, {
    aberto: 0, aprovado: 1, preparando_envio: 2, faturado: 3,
    pronto_para_envio: 4, enviado: 5, nao_entregue: 6,
    dados_incompletos: 7, cancelado: 8
  }
  enum :price_list, { standard: 0, transfer: 1 }
  enum :freight_paid_by, { shipper: 0, recipient: 1 }

  # Serviços de frete do Correios Log (forma_frete no Tiny). O fluxo dos Correios do Honey
  # (CreateCorreiosLogOrdersJob2) só aceita exatamente estes nomes.
  FREIGHT_SERVICES = ['SEDEX CORREIOS LOG+', 'PAC CORREIOS LOG+', 'SEDEX HOJE LOG+'].freeze

  STATUS_LABELS = {
    'aberto' => 'Aberto', 'aprovado' => 'Aprovado', 'preparando_envio' => 'Preparando Envio',
    'faturado' => 'Faturado', 'pronto_para_envio' => 'Pronto para Envio', 'enviado' => 'Enviado',
    'nao_entregue' => 'Não Entregue', 'dados_incompletos' => 'Dados Incompletos',
    'cancelado' => 'Cancelado'
  }.freeze

  TINY_SITUATION_MAP = {
    'Aberto' => 'aberto', 'Aprovado' => 'aprovado', 'Preparando Envio' => 'preparando_envio',
    'Faturado' => 'faturado', 'Pronto para Envio' => 'pronto_para_envio', 'Enviado' => 'enviado',
    'Não Entregue' => 'nao_entregue', 'Cancelado' => 'cancelado',
    'Dados Incompletos' => 'dados_incompletos'
  }.freeze

  validates :freight_service, inclusion: { in: FREIGHT_SERVICES }, allow_blank: true
  validates :client, presence: true, if: :sale?
  validates :transfer_location, presence: true, if: :stock_transfer?
  validates :shipping_street, :shipping_number, :shipping_neighbourhood, :shipping_city,
            :shipping_state, :shipping_zip, presence: true, if: :different_shipping_address?
  validate :must_have_items

  scope :recent, -> { order(created_at: :desc) }

  # Só dá para excluir pedido que não está no Tiny (sem referência) e sem nota fiscal ativa.
  # Se já foi enviado, o caminho é "Cancelar no Tiny" (que desvincula) e depois excluir.
  def deletable?
    tiny_reference_id.blank? && !FiscalNote.active_for?(self)
  end

  def resendable?
    !cancelado? && tiny_reference_id.blank?
  end

  def total
    b2b_order_items.sum(&:line_total)
  end

  private

  def must_have_items
    errors.add(:base, 'Pedido precisa ter pelo menos um item') if b2b_order_items.empty?
  end
end
