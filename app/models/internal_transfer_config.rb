# Configuração única das transferências internas: quem é o aprovador. Toda transferência precisa
# da aprovação dele antes de qualquer remessa ser reservada (debitada) na origem.
class InternalTransferConfig < ApplicationRecord
  belongs_to :approver, class_name: 'User', optional: true

  def self.current
    first_or_create!
  end

  def self.approver_id
    current.approver_id
  end
end
