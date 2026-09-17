# app/models/client.rb
class Client < ApplicationRecord
  validates :responsible_name, presence: true
  validates :registration, uniqueness: { allow_blank: true },
                           format: { with: /\A\d{3}\.?\d{3}\.?\d{3}-?\d{2}\z|\A\d{2}\.?\d{3}\.?\d{3}\/?\d{4}-?\d{2}\z/,
                                     message: 'deve ser um CPF ou CNPJ válido',
                                     allow_blank: true }

  def cnpj_formatted
    return registration if registration.blank?

    digits = registration.gsub(/\D/, '')
    if digits.length == 11
      digits.sub(/(\d{3})(\d{3})(\d{3})(\d{2})/, '\1.\2.\3-\4')
    else
      digits.sub(/(\d{2})(\d{3})(\d{3})(\d{4})(\d{2})/, '\1.\2.\3/\4-\5')
    end
  end

  def display_name
    business_name.presence || responsible_name
  end
end