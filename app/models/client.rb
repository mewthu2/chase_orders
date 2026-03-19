# app/models/client.rb
class Client < ApplicationRecord
  validates :responsible_name, presence: true
  validates :registration, uniqueness: { allow_blank: true },
                           format: { with: /\A\d{2}\.?\d{3}\.?\d{3}\/?\d{4}-?\d{2}\z/,
                                     message: 'deve ser um CNPJ válido',
                                     allow_blank: true }

  def cnpj_formatted
    return registration if registration.blank?
    registration.gsub(/\D/, '').sub(/(\d{2})(\d{3})(\d{3})(\d{4})(\d{2})/, '\1.\2.\3/\4-\5')
  end

  def display_name
    business_name.presence || responsible_name
  end
end