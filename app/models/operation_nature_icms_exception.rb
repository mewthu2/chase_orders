# Exceção do ICMS de uma natureza de operação (como no Tiny): quando o destinatário é de uma das UFs de destino
# (e o emitente de uma das UFs de origem, se informadas), a nota usa esta tributação no lugar da regra geral.
# A alíquota vale também na operação interestadual, no lugar da tabela 12%/7% (mercadoria importada segue com 4%).
class OperationNatureIcmsException < ApplicationRecord
  belongs_to :operation_nature, inverse_of: :icms_exceptions

  before_validation :normalize

  validates :destination_states, presence: { message: 'escolha ao menos uma UF' }
  validates :icms_situation, inclusion: { in: OperationNature::ICMS_SITUATIONS.keys }
  validates :cfop, format: { with: /\A[?1-7]\d{3}\z/, message: 'deve ter 4 dígitos (use ? no primeiro para 5/6)' }, allow_blank: true
  validates :icms_rate, :fcp_rate, numericality: { greater_than_or_equal_to: 0, less_than: 100 }
  validates :icms_rate, numericality: { greater_than: 0, message: 'é obrigatória para ICMS tributado' }, if: -> { icms_situation == '00' }
  validate :states_are_valid

  def applies_to?(company_state:, recipient_state:)
    destination_states.include?(recipient_state) && (origin_states.blank? || origin_states.include?(company_state))
  end

  def cfop_for(company_state:, recipient_state:)
    return if cfop.blank?
    return cfop unless cfop.start_with?('?')

    "#{company_state == recipient_state ? '5' : '6'}#{cfop[1..]}"
  end

  # "CE · CFOP 6152 · ICMS 00 7%" para listas.
  def summary
    origin = origin_states.present? ? " (emitente #{origin_states.join(', ')})" : ''
    "#{destination_states.join(', ')}#{origin} · CFOP #{cfop.presence || 'da regra geral'} · ICMS #{icms_situation} #{icms_rate.to_s('F')}%"
  end

  private

  def normalize
    self.destination_states = clean_states(destination_states)
    self.origin_states = clean_states(origin_states).presence
    self.cfop = cfop.to_s.delete('.').strip.presence
    self.notes = notes.to_s.strip.presence
    self.fisco_notes = fisco_notes.to_s.strip.presence
  end

  def clean_states(list)
    Array(list).flat_map { |s| s.to_s.split(/[\s,;]+/) }.map { |s| s.strip.upcase }.reject(&:blank?).uniq.sort
  end

  def states_are_valid
    invalid = (Array(destination_states) + Array(origin_states)).reject { |uf| Company::STATES.key?(uf) }
    errors.add(:base, "UF inválida na exceção do ICMS: #{invalid.join(', ')}") if invalid.any?
  end
end
