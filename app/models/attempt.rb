class Attempt < ApplicationRecord
  enum status: [:fail, :error, :success]
  enum kinds: [:create_correios_order, :send_xml, :emission_invoice]
  # Callbacks
  # Associacoes

  # Validacoes

  # Escopos

  # Metodos estaticos
  # Metodos publicos
  # Metodos GET
  # Metodos SET

  # Nota: os metodos somente utilizados em callbacks ou utilizados somente por essa
  #       propria classe deverao ser privados (remover essa anotacao)
end
