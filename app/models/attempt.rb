class Attempt < ApplicationRecord
  enum status: [:fail, :error, :success]
  enum kinds: [:create_correios_order, :send_xml, :emission_invoice, :get_tracking]
  # Callbacks
  # Associacoes

  # Validacoes

  # Escopos
  add_scope :search do |value|
    where('attempts.tiny_order_id LIKE :valor OR
           attempts.order_correios_id LIKE :valor OR
           attempts.id LIKE :valor', valor: "#{value}%")
  end
  # Metodos estaticos
  # Metodos publicos
  # Metodos GET
  # Metodos SET

  # Nota: os metodos somente utilizados em callbacks ou utilizados somente por essa
  #       propria classe deverao ser privados (remover essa anotacao)
end
