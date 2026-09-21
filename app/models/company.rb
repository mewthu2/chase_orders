# Empresa emissora de NF-e. Guarda os dados fiscais e o certificado digital A1
# (arquivo .pfx no Bucketeer via Active Storage; senha criptografada).
class Company < ApplicationRecord
  STATES = { 'AC' => '12', 'AL' => '27', 'AP' => '16', 'AM' => '13', 'BA' => '29', 'CE' => '23', 'DF' => '53',
             'ES' => '32', 'GO' => '52', 'MA' => '21', 'MT' => '51', 'MS' => '50', 'MG' => '31', 'PA' => '15',
             'PB' => '25', 'PR' => '41', 'PE' => '26', 'PI' => '22', 'RJ' => '33', 'RN' => '24', 'RS' => '43',
             'RO' => '11', 'RR' => '14', 'SC' => '42', 'SP' => '35', 'SE' => '28', 'TO' => '17' }.freeze
  TAX_REGIMES = { 1 => 'Simples Nacional', 2 => 'Simples Nacional - excesso de sublimite', 3 => 'Regime Normal' }.freeze
  EXPIRING_DAYS = 30

  enum :environment, { producao: 1, homologacao: 2 }

  has_many :fiscal_notes, dependent: :restrict_with_error
  has_one_attached :certificate
  encrypts :certificate_password

  # Arquivo .pfx recebido do formulário (não persistido; vai para o Active Storage).
  attr_accessor :certificate_file

  before_validation :normalize_cnpj
  validate :cnpj_checksum
  validate :certificate_matches_company

  validates :legal_name, :street, :number, :neighbourhood, :city, :city_ibge_code, :zip, presence: true
  validates :cnpj, presence: true, uniqueness: true
  validates :state, inclusion: { in: STATES.keys }
  validates :tax_regime, inclusion: { in: TAX_REGIMES.keys }
  validates :nfe_series, :next_nfe_number, numericality: { only_integer: true, greater_than: 0 }
  validates :cfop_sale_in_state, :cfop_sale_out_of_state, :cfop_transfer_in_state, :cfop_transfer_out_of_state,
            format: { with: /\A\d{4}\z/, message: 'deve ter 4 dígitos' }

  scope :active, -> { where(active: true) }
  scope :ready_to_issue, -> { active.where('certificate_expires_at > ?', Time.current) }

  def cnpj_formatted
    Nfe::Cnpj.format(cnpj)
  end

  def state_code
    STATES[state]
  end

  def certificate_status
    return :missing unless certificate.attached? && certificate_expires_at
    return :expired if certificate_expires_at < Time.current
    return :expiring if certificate_expires_at < EXPIRING_DAYS.days.from_now

    :valid
  end

  def ready_to_issue?
    active? && %i[valid expiring].include?(certificate_status)
  end

  def nfe_certificate
    Nfe::Certificate.new(certificate.download, certificate_password)
  end

  private

  def normalize_cnpj
    self.cnpj = Nfe::Cnpj.digits(cnpj)
  end

  def cnpj_checksum
    errors.add(:cnpj, 'deve ser um CNPJ válido') if cnpj.present? && !Nfe::Cnpj.valid?(cnpj)
  end

  # Valida o certificado enviado (ou o já salvo, se só a senha mudou): senha correta,
  # não vencido e do mesmo CNPJ da empresa. Guarda validade/assunto para consulta rápida.
  def certificate_matches_company
    if certificate_file.present?
      certificate_file.rewind if certificate_file.respond_to?(:rewind)
      data = certificate_file.read
    end
    if data.nil?
      return unless persisted? && certificate.attached? && certificate_password_changed?

      data = certificate.download
    end

    return errors.add(:certificate_password, 'é obrigatória para o certificado') if certificate_password.blank?

    cert = Nfe::Certificate.new(data, certificate_password)
    return errors.add(:certificate_file, 'está vencido') if cert.expired?
    return errors.add(:certificate_file, 'pertence a outro CNPJ') if cert.cnpj != cnpj

    self.certificate_expires_at = cert.expires_at
    self.certificate_subject = cert.subject
    self.certificate_cnpj = cert.cnpj
    return unless certificate_file.present?

    self.certificate = { io: StringIO.new(data), filename: 'certificado.pfx', content_type: 'application/x-pkcs12' }
  rescue Nfe::Certificate::Error => e
    errors.add(:certificate_file, e.message)
  end
end
