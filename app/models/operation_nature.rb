# Natureza de operação no molde do Tiny: descrição (vai no natOp), CFOP da regra geral e a tributação usada nos
# itens da nota. O CFOP aceita "?102": o primeiro dígito vira 5 (mesma UF) ou 6 (outra UF) na hora de emitir.
class OperationNature < ApplicationRecord
  KINDS = { 'sale' => 'Venda', 'transfer' => 'Transferência', 'other' => 'Outra' }.freeze
  PURPOSES = { 1 => 'Normal', 2 => 'Complementar', 3 => 'Ajuste', 4 => 'Devolução' }.freeze
  ICMS_SITUATIONS = {
    '00' => '00 - Tributada integralmente', '40' => '40 - Isenta', '41' => '41 - Não tributada', '50' => '50 - Suspensão',
    '102' => '102 - Simples sem permissão de crédito', '103' => '103 - Simples com isenção por faixa',
    '300' => '300 - Imune', '400' => '400 - Não tributada pelo Simples'
  }.freeze
  PIS_COFINS_SITUATIONS = {
    '01' => '01 - Tributável (alíquota básica)', '02' => '02 - Tributável (alíquota diferenciada)',
    '04' => '04 - Monofásica (revenda a alíquota zero)', '06' => '06 - Alíquota zero', '07' => '07 - Isenta',
    '08' => '08 - Sem incidência', '09' => '09 - Suspensão', '49' => '49 - Outras operações de saída',
    '99' => '99 - Outras operações'
  }.freeze
  TAXED_PIS_COFINS = %w[01 02].freeze
  # IBS e CBS (reforma tributária). "auto" é o que o emissor sempre fez: destaca na venda a consumidor final do
  # Regime Normal e, na transferência entre lojas, vai só com CST 410 (não incidência).
  IBS_CBS_MODES = {
    'auto' => 'Automático (consumidor final no Regime Normal; transferência sem valores)',
    'taxed' => 'Destacar sempre (Regime Normal)',
    'no_values' => 'Só CST e cClassTrib, sem valores',
    'off' => 'Não informar o grupo IBS/CBS'
  }.freeze
  IBS_CBS_SITUATIONS = {
    '000' => '000 - Tributação integral', '200' => '200 - Alíquota reduzida', '410' => '410 - Imunidade e não incidência',
    '510' => '510 - Diferimento', '550' => '550 - Suspensão', '620' => '620 - Tributação monofásica',
    '800' => '800 - Transferência de crédito', '810' => '810 - Ajustes', '820' => '820 - Tributação em declaração de regime específico'
  }.freeze
  # Variáveis aceitas nas observações.
  NOTE_VARIABLES = %w[{pedido} {cliente}].freeze

  belongs_to :company
  has_many :fiscal_notes, dependent: :restrict_with_error
  has_many :company_links, class_name: 'CompanyOperationNature', dependent: :destroy
  has_many :linked_companies, through: :company_links, source: :company
  has_many :icms_exceptions, -> { order(:id) }, class_name: 'OperationNatureIcmsException', dependent: :destroy,
                                                inverse_of: :operation_nature
  accepts_nested_attributes_for :icms_exceptions, allow_destroy: true,
                                                  reject_if: ->(attrs) { Array(attrs['destination_states']).reject(&:blank?).empty? && attrs['id'].blank? }
  # A empresa em que a natureza é criada já fica vinculada a ela.
  after_create { company_links.find_or_create_by(company: company) }

  enum :kind, { sale: 0, transfer: 1, other: 2 }

  before_validation :normalize
  after_save :unset_other_defaults, if: -> { default_for_kind? && saved_change_to_default_for_kind? }

  validates :description, presence: true, length: { maximum: 60 }
  validates :cfop, format: { with: /\A[?1-7]\d{3}\z/, message: 'deve ter 4 dígitos (use ? no primeiro para 5/6)' }
  validates :cfop_interstate_non_contributor, format: { with: /\A6\d{3}\z/, message: 'deve começar com 6' }, allow_blank: true
  validates :purpose, inclusion: { in: PURPOSES.keys }
  validates :icms_situation, inclusion: { in: ICMS_SITUATIONS.keys }
  validates :pis_cst, :cofins_cst, inclusion: { in: PIS_COFINS_SITUATIONS.keys }
  validates :icms_rate, :pis_rate, :cofins_rate, numericality: { greater_than_or_equal_to: 0, less_than: 100 }
  validates :icms_rate, numericality: { greater_than: 0, message: 'é obrigatória para ICMS tributado' }, if: -> { icms_situation == '00' }
  validates :ibs_cbs_mode, inclusion: { in: IBS_CBS_MODES.keys }
  validates :ibs_cbs_cst, format: { with: /\A\d{3}\z/, message: 'deve ter 3 dígitos' }
  validates :ibs_cbs_class, format: { with: /\A\d{6}\z/, message: 'deve ter 6 dígitos' }
  validates :ibs_uf_rate, :ibs_mun_rate, :cbs_rate, numericality: { greater_than_or_equal_to: 0, less_than: 100 }
  validate :situations_match_company_regime
  validate :linked_companies_still_compatible, on: :update
  validate :exceptions_match_company_regime

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:description) }

  SIMPLES_CODES = %w[102 103 300 400].freeze

  # Natureza padrão de um tipo entre as vinculadas à empresa.
  def self.default_for(company, kind)
    company.available_natures.active.where(kind: kind).order(default_for_kind: :desc, id: :asc).first
  end

  def compatible_with?(company)
    (company.tax_regime != 3) == SIMPLES_CODES.include?(icms_situation)
  end

  def regime_label
    SIMPLES_CODES.include?(icms_situation) ? 'CSOSN (Simples Nacional)' : 'CST (Regime Normal)'
  end

  # Texto curto para listas: "Venda de mercadoria · CFOP ?102 · ICMS 102".
  def summary
    "#{description} · CFOP #{cfop} · ICMS #{icms_situation}"
  end

  # Primeira exceção do ICMS que vale para o emitente e o destinatário (como no Tiny, a de cima ganha).
  def icms_exception_for(company_state:, recipient_state:)
    icms_exceptions.reject(&:marked_for_destruction?)
                   .find { |exception| exception.applies_to?(company_state: company_state, recipient_state: recipient_state) }
  end

  # CFOP do item conforme o destino. A exceção do ICMS com CFOP próprio ganha; depois, para consumidor não
  # contribuinte de outra UF usa o CFOP próprio, se houver.
  def cfop_for(company_state:, recipient_state:, non_contributor: false)
    exception_cfop = icms_exception_for(company_state: company_state, recipient_state: recipient_state)
                     &.cfop_for(company_state: company_state, recipient_state: recipient_state)
    return exception_cfop if exception_cfop

    same_state = company_state == recipient_state
    return cfop_interstate_non_contributor if !same_state && non_contributor && cfop_interstate_non_contributor.present?
    return cfop unless %w[? 5 6].include?(cfop[0])

    "#{same_state ? '5' : '6'}#{cfop[1..]}"
  end

  def rates_for(state)
    row = (uf_rates.presence || Nfe::IcmsRates.default_table)[state] || {}
    { internal: BigDecimal(row['internal'].presence || '0'), fcp: BigDecimal(row['fcp'].presence || '0') }
  end

  def icms_taxed?
    icms_situation == '00'
  end

  # Tributação no formato do Nfe::XmlBuilder. Com as UFs do emitente e do destinatário aplica a exceção do ICMS,
  # se houver: CST, alíquota (inclusive interestadual: icms_rate_fixed), DIFAL e FCP da exceção.
  def tax_rules(company_state: nil, recipient_state: nil)
    rules = {
      icms_situation: icms_situation, icms_rate: icms_rate, difal: difal?, uf_rates: ->(state) { rates_for(state) },
      pis_cst: pis_cst, pis_rate: pis_rate, cofins_cst: cofins_cst, cofins_rate: cofins_rate,
      exclude_icms_from_pis_cofins_base: exclude_icms_from_pis_cofins_base?,
      ibs_cbs: { mode: ibs_cbs_mode, cst: ibs_cbs_cst, class: ibs_cbs_class, ibs_uf: BigDecimal(ibs_uf_rate.to_s),
                 ibs_mun: BigDecimal(ibs_mun_rate.to_s), cbs: BigDecimal(cbs_rate.to_s) }
    }
    exception = icms_exception_for(company_state: company_state, recipient_state: recipient_state)
    return rules unless exception

    rules.merge(
      icms_situation: exception.icms_situation, icms_rate: exception.icms_rate, icms_rate_fixed: true,
      difal: exception.difal?,
      uf_rates: lambda { |state|
        rates = rates_for(state)
        exception.fcp_rate.positive? ? rates.merge(fcp: BigDecimal(exception.fcp_rate.to_s)) : rates
      }
    )
  end

  # Observações da nota: as da natureza mais as da exceção do ICMS (sem repetir o mesmo texto).
  def notes_for(company_state:, recipient_state:, **vars)
    exception = icms_exception_for(company_state: company_state, recipient_state: recipient_state)
    join_notes(render_notes(notes, **vars), exception && render_notes(exception.notes, **vars))
  end

  def fisco_notes_for(company_state:, recipient_state:, **vars)
    exception = icms_exception_for(company_state: company_state, recipient_state: recipient_state)
    join_notes(render_notes(fisco_notes, **vars), exception && render_notes(exception.fisco_notes, **vars))
  end

  def render_notes(text, order_name: nil, customer: nil)
    text.to_s.gsub('{pedido}', order_name.to_s).gsub('{cliente}', customer.to_s).strip.presence
  end

  def kind_label
    KINDS[kind]
  end

  private

  def join_notes(*texts)
    texts.compact.uniq.join(' | ').presence
  end

  def exceptions_match_company_regime
    return unless company

    simples = company.tax_regime != 3
    icms_exceptions.reject(&:marked_for_destruction?).each do |exception|
      next if SIMPLES_CODES.include?(exception.icms_situation) == simples

      errors.add(:base, "Exceção do ICMS (#{exception.destination_states.to_a.join(', ')}): use #{simples ? 'um CSOSN' : 'um CST'}, como na regra geral.")
    end
  end

  def normalize
    self.cfop = cfop.to_s.delete('.').strip
    self.cfop_interstate_non_contributor = cfop_interstate_non_contributor.to_s.delete('.').strip.presence
    self.ibs_cbs_cst = ibs_cbs_cst.to_s.strip
    self.ibs_cbs_class = ibs_cbs_class.to_s.delete('.').strip
    self.uf_rates = Nfe::IcmsRates.default_table if uf_rates.blank?
  end

  def situations_match_company_regime
    return unless company

    simples = company.tax_regime != 3
    simples_codes = %w[102 103 300 400]
    if simples && !simples_codes.include?(icms_situation)
      errors.add(:icms_situation, 'deve ser um CSOSN (empresa do Simples Nacional)')
    elsif !simples && simples_codes.include?(icms_situation)
      errors.add(:icms_situation, 'deve ser um CST (empresa do Regime Normal)')
    end
  end

  def linked_companies_still_compatible
    bad = linked_companies.reject { |c| compatible_with?(c) }
    errors.add(:icms_situation, "não serve para #{bad.map(&:legal_name).to_sentence}, que usa esta natureza") if bad.any?
  end

  def unset_other_defaults
    company.operation_natures.where(kind: kind).where.not(id: id).update_all(default_for_kind: false)
  end
end
