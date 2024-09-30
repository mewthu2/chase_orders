class Order < ApplicationRecord
  enum kinds: [:lagoa_seca, :bh_shopping]
  # Callbacks
  # Associacoes
  has_many :order_items
  # Validacoes

  # Escopos
  # Metodos estaticos
  # Metodos publicos
  # Metodos GET
  # Metodos SET

  # Nota: os metodos somente utilizados em callbacks ou utilizados somente por essa
  #       propria classe deverao ser privados (remover essa anotacao)
end
