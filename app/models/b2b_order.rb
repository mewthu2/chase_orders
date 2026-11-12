class B2bOrder < ApplicationRecord
  belongs_to :client, optional: true
  belongs_to :transfer_location, optional: true
  belongs_to :carrier, optional: true
  belongs_to :user
  has_many :b2b_order_items, dependent: :destroy
  accepts_nested_attributes_for :b2b_order_items, allow_destroy: true, reject_if: :all_blank

  has_many :fiscal_notes, dependent: :nullify

  # b2c_transfer: transferência do estoque B2B para a filial B2C (destinatário fixo, ver B2bTinyService).
  enum :kind, { sale: 0, stock_transfer: 1, b2c_transfer: 2 }
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
  # Pedido do atacado: Correios Log só por SEDEX (ou transportadora, que não usa serviço).
  SALE_FREIGHT_SERVICES = ['SEDEX CORREIOS LOG+'].freeze

  # Forma de pagamento combinada com o cliente do atacado. É só registro: vai nas observações do pedido no
  # Tiny, sem gerar cobrança.
  PAYMENT_METHODS = { 'boleto' => 'Boleto', 'pix' => 'PIX', 'cartao' => 'Cartão' }.freeze
  DISCOUNT_TYPES = { 'amount' => 'R$', 'percent' => '%' }.freeze

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
  validates :freight_service, inclusion: { in: SALE_FREIGHT_SERVICES, message: 'do atacado é só SEDEX' },
                              allow_blank: true, if: -> { sale? && freight_service_changed? }
  validates :payment_method, inclusion: { in: PAYMENT_METHODS.keys }, allow_blank: true
  # Exigida no formulário do atacado e no envio ao Tiny (require_payment); pedidos já enviados ao Tiny
  # antes deste campo existir continuam editáveis sem ele.
  attr_accessor :require_payment
  validates :payment_method, presence: true, if: -> { require_payment && sale? && tiny_reference_id.blank? }
  validates :order_discount_type, inclusion: { in: DISCOUNT_TYPES.keys }
  validates :order_discount, numericality: { greater_than_or_equal_to: 0 }
  validates :order_discount, numericality: { less_than_or_equal_to: 100, message: 'em porcentagem vai até 100%' }, if: :percent_discount?
  validate :discount_within_items_total
  validates :client, presence: true, if: :sale?
  validates :transfer_location, presence: true, if: :stock_transfer?
  # Mão própria: os Correios só entregam para o destinatário nomeado, que é quem recebe na loja.
  # Abastecimentos já enviados antes deste campo existir continuam editáveis sem ele.
  validates :receiver_name, presence: true, if: -> { hand_delivery? && tiny_reference_id.blank? }
  # Vários responsáveis são guardados juntos, separados por vírgula.
  validates :receiver_name, length: { maximum: 255 }
  validates :shipping_street, :shipping_number, :shipping_neighbourhood, :shipping_city,
            :shipping_state, :shipping_zip, presence: true, if: :different_shipping_address?
  validate :must_have_items

  scope :recent, -> { order(created_at: :desc) }

  # Pedido sem nota fiscal ativa pode ser excluído. Se já está no Tiny como pedido, a exclusão cancela o
  # pedido lá antes (a API do Tiny não exclui pedido); o abastecimento antigo, que virou nota fiscal no
  # Tiny, não pode ser excluído por aqui.
  def deletable?
    (tiny_reference_id.blank? || tiny_order?) && !FiscalNote.active_for?(self)
  end

  def resendable?
    !cancelado? && tiny_reference_id.blank?
  end

  # Vira pedido de venda no Tiny (pedido.incluir), com situação sincronizada e cancelável por lá.
  # Todos os tipos viram pedido, menos o abastecimento antigo, que virou nota fiscal direto.
  def tiny_order?
    !legacy_invoice?
  end

  # Abastecimentos enviados antes de virarem pedido foram criados como nota fiscal no Tiny: o
  # tiny_reference_id deles é o número da nota (igual ao tiny_reference_number). Num pedido o id
  # do Tiny nunca é igual ao número.
  def legacy_invoice?
    stock_transfer? && tiny_reference_id.present? && tiny_reference_id.to_s == tiny_reference_number.to_s
  end

  def items_total
    b2b_order_items.reject(&:marked_for_destruction?).sum(&:line_total)
  end

  def percent_discount?
    order_discount_type == 'percent'
  end

  # Desconto livre do pedido em reais (a porcentagem incide sobre o total dos itens).
  def discount_amount
    value = order_discount.to_d
    amount = percent_discount? ? (items_total.to_d * value / 100) : value
    [amount.round(2), items_total.to_d].min
  end

  # Total dos produtos já com o desconto do pedido (o frete fica à parte).
  def total
    items_total.to_d - discount_amount
  end

  def payment_label
    PAYMENT_METHODS[payment_method]
  end

  # Abastecimento sem transportadora escolhida vai por SEDEX com mão própria; com transportadora, vai por ela.
  def hand_delivery?
    stock_transfer? && carrier_id.blank?
  end

  def stock_transfer_by_carrier?
    stock_transfer? && carrier_id.present?
  end

  private

  def must_have_items
    errors.add(:base, 'Pedido precisa ter pelo menos um item') if b2b_order_items.empty?
  end

  def discount_within_items_total
    return if percent_discount? || order_discount.to_d <= items_total.to_d

    errors.add(:order_discount, 'não pode ser maior que o total dos itens')
  end
end
