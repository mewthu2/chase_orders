# Carta de correção (CC-e) registrada na SEFAZ para uma NF-e: evento 110110, gravado pelo Nfe::CorrectionLetter.
# A última (maior sequência) é a que vale: cada carta nova substitui as anteriores.
class FiscalNoteCorrection < ApplicationRecord
  belongs_to :fiscal_note
  has_one_attached :xml

  validates :sequence, presence: true, uniqueness: { scope: :fiscal_note_id }
  validates :correction, presence: true

  def current?
    fiscal_note.corrections.maximum(:sequence) == sequence
  end
end
