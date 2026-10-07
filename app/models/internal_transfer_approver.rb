# Quem aprova as transferências internas. Toda transferência precisa da aprovação de um deles (ou
# de um admin, que aprova sempre) antes de qualquer remessa ser reservada (debitada) na origem.
class InternalTransferApprover < ApplicationRecord
  belongs_to :user

  validates :user_id, uniqueness: true

  def self.user_ids
    pluck(:user_id)
  end

  def self.can_approve?(user)
    user.admin? || exists?(user_id: user.id)
  end

  # Troca a lista inteira pelos usuários informados.
  def self.replace_with!(user_ids)
    ids = User.where(id: user_ids).ids
    transaction do
      where.not(user_id: ids).delete_all
      (ids - self.user_ids).each { |id| create!(user_id: id) }
    end
  end
end
