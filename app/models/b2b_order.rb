class B2bOrder < ApplicationRecord
  belongs_to :client, optional: true
  belongs_to :transfer_location, optional: true
  belongs_to :carrier, optional: true
  # Dados da NF-e editáveis na aba Nota fiscal antes da autorização (Nfe::Generator usa na emissão).
  belongs_to :nf_carrier, class_name: 'Carrier', optional: true
  NF_FREIGHT_MODES = { '0' => 'Por conta do remetente (CIF)', '1' => 'Por conta do destinatário (FOB)', '2' => 'Por conta de terceiros',
                       '3' => 'Transporte próprio do remetente', '4' => 'Transporte próprio do destinatário', '9' => 'Sem frete' }.freeze
  validates :nf_freight_mode, inclusion: { in: NF_FREIGHT_MODES.keys }, allow_blank: true
  validates :nf_additional_info, length: { maximum: 4000 }
  belongs_to :user
  has_many :b2b_order_items, dependent: :destroy
  accepts_nested_attributes_for :b2b_order_items, allow_destroy: true, reject_if: :all_blank

  has_many :fiscal_notes, dependent: :nullify
  has_many :attempts, dependent: :nullify

  # b2c_transfer: transferência do estoque B2B para a filial B2C (destinatário fixo, ver B2bTinyService).
  enum :kind, { sale: 0, stock_transfer: 1, b2c_transfer: 2 }
  # Sentido da transferência B2C. b2c_to_b2b não entra no Log02 nem no Correios e não reserva estoque: só gera a
  # nota de transferência (emitida pela filial B2C) e a de remessa (emitida pela filial B2B).
  enum :transfer_direction, { b2b_to_b2c: 0, b2c_to_b2b: 1 }, validate: true
  DIRECTION_LABELS = { 'b2b_to_b2c' => 'B2B → B2C', 'b2c_to_b2b' => 'B2C → B2B' }.freeze
  enum :status, {
    aberto: 0, aprovado: 1, preparando_envio: 2, faturado: 3,
    pronto_para_envio: 4, enviado: 5, nao_entregue: 6,
    dados_incompletos: 7, cancelado: 8
  }
  enum :price_list, { standard: 0, transfer: 1 }
  enum :freight_paid_by, { shipper: 0, recipient: 1 }

  # Serviços de frete do Correios Log (forma_frete no Tiny). O fluxo dos Correios do Honey
  # (HoneyB2bLog) só aceita exatamente estes nomes.
  FREIGHT_SERVICES = ['SEDEX CORREIOS LOG+', 'PAC CORREIOS LOG+', 'SEDEX HOJE LOG+'].freeze
  # Pedido do atacado: Correios Log só por SEDEX (ou transportadora, que não usa serviço).
  SALE_FREIGHT_SERVICES = ['SEDEX CORREIOS LOG+'].freeze
  # Abastecimento por SEDEX normal (sem mão própria).
  STOCK_TRANSFER_SEDEX = 'SEDEX CORREIOS LOG+'.freeze

  # Forma de pagamento combinada com o cliente do atacado. É só registro: vai nas observações do pedido no
  # Tiny, sem gerar cobrança.
  PAYMENT_METHODS = { 'boleto' => 'Boleto', 'pix' => 'PIX', 'cartao' => 'Cartão' }.freeze
  DISCOUNT_TYPES = { 'amount' => 'R$', 'percent' => '%' }.freeze
  # Boleto e cartão podem ser parcelados: a condição de pagamento lista os dias de cada vencimento, como no Tiny.
  INSTALLMENT_METHODS = %w[boleto cartao].freeze
  MAX_INSTALLMENTS = 12

  STATUS_LABELS = {
    'aberto' => 'Aberto', 'aprovado' => 'Aprovado', 'preparando_envio' => 'Preparando Envio',
    'faturado' => 'Faturado', 'pronto_para_envio' => 'Pronto para Envio', 'enviado' => 'Enviado',
    'nao_entregue' => 'Não Entregue', 'dados_incompletos' => 'Dados Incompletos',
    'cancelado' => 'Cancelado'
  }.freeze

  validates :freight_service, inclusion: { in: FREIGHT_SERVICES }, allow_blank: true
  validates :freight_service, inclusion: { in: SALE_FREIGHT_SERVICES, message: 'do atacado é só SEDEX' },
                              allow_blank: true, if: -> { sale? && freight_service_changed? }
  validates :freight_service, inclusion: { in: [STOCK_TRANSFER_SEDEX], message: 'do abastecimento é só SEDEX' },
                              allow_blank: true, if: -> { stock_transfer? && freight_service_changed? }
  # Abastecimento por transportadora não leva serviço de frete (senão viraria SEDEX).
  before_validation(if: :stock_transfer?) { self.freight_service = nil if carrier_id.present? }
  validates :payment_method, inclusion: { in: PAYMENT_METHODS.keys }, allow_blank: true
  # Exigida no formulário do atacado e no envio ao Tiny (require_payment); pedidos já enviados ao Tiny
  # antes deste campo existir continuam editáveis sem ele.
  attr_accessor :require_payment
  validates :payment_method, presence: true, if: -> { require_payment && sale? && tiny_reference_id.blank? }
  validates :order_discount_type, inclusion: { in: DISCOUNT_TYPES.keys }
  validates :order_discount, numericality: { greater_than_or_equal_to: 0 }
  validates :order_discount, numericality: { less_than_or_equal_to: 100, message: 'em porcentagem vai até 100%' }, if: :percent_discount?
  validate :discount_within_items_total
  validates :payment_terms, format: { with: /\A\d{1,3}(\s+\d{1,3})*\z/, message: 'deve ter só os dias de cada parcela, separados por espaço (ex.: 30 60 90)' },
                            allow_blank: true
  validate :payment_terms_fit

  # Retirada: o cliente busca no galpão, sem serviço de frete, transportadora nem valor de frete.
  # Frete da tabela: o valor sai da faixa do valor do pedido (Tabela de frete do atacado).
  before_validation :apply_shipping_mode, if: :sale?

  # PIX (ou sem forma) é à vista: sem parcelas. Vírgulas e barras viram espaço ("30/60/90" => "30 60 90").
  before_validation do
    self.payment_terms = INSTALLMENT_METHODS.include?(payment_method) ? payment_terms.to_s.tr(',;/', '   ').squish.presence : nil
  end
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
  # Pedidos que rodam no Log02 direto do Honey (nunca foram ao Tiny).
  scope :honey_flow, -> { where(tiny_reference_id: [nil, '']).where.not(transfer_direction: transfer_directions[:b2c_to_b2b]) }
  # Ainda não viraram pedido no Correios: reservam o estoque do Log02.
  scope :reserving_stock, -> { honey_flow.where(correios_order_id: nil, log_ignored: false).where.not(status: :cancelado) }

  # Filas do Log02 depois da criação no Correios. Pedido já no Correios com log_ignored foi concluído à mão: sai das duas.
  scope :waiting_xml, -> { honey_flow.where.not(correios_order_id: nil).where(xml_sent_at: nil, log_ignored: false).where.not(status: :cancelado) }
  scope :waiting_tracking, -> { honey_flow.where.not(xml_sent_at: nil).where(tracking_code: [nil, ''], log_ignored: false).where.not(status: :cancelado) }

  # B2C → B2B reserva o estoque B2C até as duas notas de produção saírem (status faturado).
  scope :reserving_b2c_stock, -> { b2c_to_b2b.where(tiny_reference_id: [nil, '']).where.not(status: %i[cancelado faturado enviado]) }

  # Prefixo das reservas e do número no Correios dos pedidos do Honey (os ids do Tiny têm 9 dígitos começando em 9).
  RESERVATION_PREFIX = 'H'.freeze

  LOG_STAGES = {
    'review' => ['Para aprovar', 'Esperando alguém aprovar em Log02 › Pedidos p/ Aprovar.'],
    'ignored' => ['Ignorado', 'Não segue para o Correios. Dá para aprovar depois.'],
    'creation' => ['Criação no Correios', 'Aprovado: entra no Correios na próxima rodada da criação.'],
    'invoice' => ['NF-e e XML', 'Criado no Correios: falta emitir a NF-e no Honey e enviar o XML.'],
    'tracking' => ['Rastreio', 'XML enviado: esperando o Correios liberar o código de rastreio.'],
    'shipped' => ['Enviado', 'Com código de rastreio.'],
    'canceled' => ['Cancelado', 'Cancelado.'],
    'completed' => ['Concluído à mão', 'Tirado da fila à mão: o Honey não envia o XML nem busca o rastreio.'],
    'notes_only' => ['Só notas fiscais', 'B2C → B2B: não vai ao Correios, só precisa da nota de transferência e da de remessa.']
  }.freeze

  # Pedido sem nota fiscal ativa pode ser excluído. Se já está no Tiny como pedido, a exclusão cancela o
  # pedido lá antes (a API do Tiny não exclui pedido); o abastecimento antigo, que virou nota fiscal no
  # Tiny, não pode ser excluído por aqui.
  # Pedido do Honey só sai antes de virar pedido no Correios; os antigos do Tiny seguem a regra de antes.
  def deletable?
    return false if honey_flow? && correios_order_id.present?

    (tiny_reference_id.blank? || tiny_order?) && !FiscalNote.active_for?(self)
  end

  def honey_flow?
    tiny_reference_id.blank? && !b2c_to_b2b?
  end

  # Pedidos com a nota de remessa além da nota principal.
  def remessa_note?
    stock_transfer? || b2c_to_b2b?
  end

  # Origem da reserva deste pedido na escadinha (StockReservationPriority).
  def reservation_source
    return 'b2c_to_b2b' if b2c_to_b2b?

    kind
  end

  # B2C → B2B não tem etapas no Correios: fica faturado com as duas notas de produção autorizadas.
  def sync_notes_only_status!
    return if !b2c_to_b2b? || cancelado?

    roles = fiscal_notes.producao.autorizada.distinct.pluck(:role)
    status = roles.include?(nil) && roles.include?('remessa') ? :faturado : :aberto
    update_columns(status: self.class.statuses[status], updated_at: Time.current)
    HoneyB2bLog.sync_reservations!
  end

  def reservation_key
    "#{RESERVATION_PREFIX}#{id}"
  end

  # Número do pedido no Correios: 9 dígitos, como os ids do Tiny, começando em 1 para não colidir com eles.
  def correios_number
    format('1%08d', id)
  end

  def log_stage
    return 'canceled' if cancelado?
    return 'notes_only' if b2c_to_b2b?
    return 'shipped' if tracking_code.present?
    return 'completed' if correios_order_id.present? && log_ignored?
    return 'tracking' if xml_sent_at.present?
    return 'invoice' if correios_order_id.present?
    return 'ignored' if log_ignored?

    aprovado? ? 'creation' : 'review'
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

  # Total a receber: produtos com o desconto do pedido + frete.
  def grand_total
    total + freight_value.to_d
  end

  def installment_days
    payment_terms.to_s.split.map(&:to_i)
  end

  # Parcelas iguais (a última fica com a sobra dos centavos), vencendo a partir da data do pedido.
  def installments
    days = installment_days
    return [] if days.empty?

    base = (created_at || Time.current).to_date
    value = (grand_total / days.size).floor(2)
    days.each_with_index.map do |d, i|
      amount = i == days.size - 1 ? grand_total - value * (days.size - 1) : value
      { number: i + 1, days: d, date: base + d, value: amount }
    end
  end

  # "Boleto 3x (30 60 90)", "Cartão 1x (30)" ou só "PIX".
  def payment_description
    return payment_label if payment_label.nil? || installment_days.empty?

    "#{payment_label} #{installment_days.size}x (#{payment_terms})"
  end

  # Abastecimento: por transportadora (carrier_id), por SEDEX normal (freight_service preenchido, sem
  # transportadora) ou, sem nenhum dos dois, por SEDEX com mão própria (o padrão, e o dos pedidos antigos).
  def hand_delivery?
    stock_transfer? && carrier_id.blank? && freight_service.blank?
  end

  def stock_transfer_by_sedex?
    stock_transfer? && carrier_id.blank? && freight_service.present?
  end

  # "SEDEX · Mão Própria", "SEDEX" ou "Transportadora · Nome".
  def stock_delivery_label
    return 'SEDEX · Mão Própria' if hand_delivery?
    return 'SEDEX' if stock_transfer_by_sedex?

    "Transportadora · #{carrier&.name}"
  end

  def stock_transfer_by_carrier?
    stock_transfer? && carrier_id.present?
  end

  # "Correios Log", "Transportadora · Nome" ou "Retirada" (atacado).
  def shipping_label
    return 'Retirada' if pickup?
    return "Transportadora · #{carrier&.name}" if carrier_id.present? && freight_service.blank?

    freight_service.present? ? 'Correios Log' : nil
  end

  # A nota de produção que impede mudar os dados da NF-e: autorizada, assinada (indo à SEFAZ) ou sem resposta
  # (precisa ser consultada com o mesmo XML). Rejeitada ou excluída libera para corrigir e emitir de novo.
  # Destinatário da nota de remessa: o deste pedido ou, sem ele, o padrão das configurações do tipo do pedido.
  def remessa_recipient_data
    B2bSetting.normalize_recipient(remessa_recipient.presence || B2bSetting.current.remessa_recipient_data(self))
  end

  def nf_details_lock
    fiscal_notes.principal.where(environment: :producao, status: %i[rascunho assinada autorizada erro]).order(:id).last
  end

  private

  def apply_shipping_mode
    if pickup?
      self.freight_service = nil
      self.carrier_id = nil
      self.fixed_freight = false
      self.freight_value = 0
    elsif fixed_freight? && correios_order_id.blank?
      self.freight_value = B2bFreightRate.price_for(total)
    end
  end

  def must_have_items
    errors.add(:base, 'Pedido precisa ter pelo menos um item') if b2b_order_items.reject(&:marked_for_destruction?).empty?
  end

  def payment_terms_fit
    days = installment_days
    return if days.empty?

    errors.add(:payment_terms, "aceita até #{MAX_INSTALLMENTS} parcelas") if days.size > MAX_INSTALLMENTS
    errors.add(:payment_terms, 'deve ter os dias em ordem crescente, sem repetir') unless days.each_cons(2).all? { |a, b| b > a }
  end

  def discount_within_items_total
    return if percent_discount? || order_discount.to_d <= items_total.to_d

    errors.add(:order_discount, 'não pode ser maior que o total dos itens')
  end
end
