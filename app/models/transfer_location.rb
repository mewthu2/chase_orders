class TransferLocation < ApplicationRecord
  has_many :b2b_orders, dependent: :restrict_with_error

  validates :name, :street, :number, :neighbourhood, :city, :state, :zip,
            presence: true
  validates :registration, presence: true,
                           format: { with: /\A\d{2}\.?\d{3}\.?\d{3}\/?\d{4}-?\d{2}\z/,
                                     message: 'deve ser um CNPJ válido' }

  validates :city_ibge_code, format: { with: /\A\d{7}\z/, message: 'deve ter 7 dígitos' }, allow_blank: true

  scope :active, -> { where(active: true) }

  def cnpj_formatted
    registration.gsub(/\D/, '').sub(/(\d{2})(\d{3})(\d{3})(\d{4})(\d{2})/, '\1.\2.\3/\4-\5')
  end
end
