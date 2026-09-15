class Carrier < ApplicationRecord
  has_many :b2b_orders, dependent: :restrict_with_error

  validates :name, :street, :number, :neighbourhood, :city, :state, :zip,
            presence: true
  validates :registration, presence: true,
                           format: { with: /\A\d{2}\.?\d{3}\.?\d{3}\/?\d{4}-?\d{2}\z/,
                                     message: 'deve ser um CNPJ válido' }

  scope :active, -> { where(active: true) }

  def cnpj_formatted
    registration.gsub(/\D/, '').sub(/(\d{2})(\d{3})(\d{3})(\d{4})(\d{2})/, '\1.\2.\3/\4-\5')
  end

  def transmitted?
    transmitted_at.present? && tiny_contact_id.present?
  end
end
