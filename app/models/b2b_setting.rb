# Configuração do atacado (uma linha só). fixed_freight_value: frete fixo que o pedido recebe ao escolher
# "Frete fixo" (o vendedor ainda pode ajustar o valor naquele pedido).
class B2bSetting < ApplicationRecord
  validates :fixed_freight_value, numericality: { greater_than_or_equal_to: 0 }

  def self.current
    first || create!(fixed_freight_value: 0)
  end
end
