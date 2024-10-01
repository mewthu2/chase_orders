class OrderItem < ApplicationRecord
  # Callbacks
  # Associacoes
  belongs_to :order
  belongs_to :product
  # Validacoes

  # Escopos
  # Metodos estaticos
  # Metodos publicos
  # Metodos GET
  # Metodos SET

  # Nota: os metodos somente utilizados em callbacks ou utilizados somente por essa
  #       propria classe deverao ser privados (remover essa anotacao)
end
