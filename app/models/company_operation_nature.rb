# Vínculo de uma natureza de operação a uma empresa (a empresa pode emitir notas com ela).
class CompanyOperationNature < ApplicationRecord
  belongs_to :company
  belongs_to :operation_nature

  validates :operation_nature_id, uniqueness: { scope: :company_id }
  validate :regime_matches

  private

  # CSOSN só para empresa do Simples; CST só para Regime Normal.
  def regime_matches
    return unless company && operation_nature
    return if operation_nature.compatible_with?(company)

    errors.add(:base, "A natureza \"#{operation_nature.description}\" usa #{operation_nature.regime_label} e não serve para #{company.legal_name}.")
  end
end
