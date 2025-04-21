class Attempt < ApplicationRecord
  enum status: [:fail, :error, :success, :processing]
  enum kinds: [:transfer_tiny_to_shopify_order, :create_correios_order, :send_xml, :emission_invoice, :get_tracking, :create_note_tiny2, :emission_invoice_tiny2]
  # Callbacks
  # Associacoes

  # Validacoes

  # Escopos
  add_scope :search do |value|
    where('attempts.tiny_order_id LIKE :valor OR
           attempts.order_correios_id LIKE :valor OR
           attempts.error LIKE :valor OR
           attempts.message LIKE :valor OR
           attempts.id LIKE :valor', valor: "#{value}%")
  end
  # Metodos estaticos
  # Metodos publicos
  # Metodos GET
  # Metodos SET

  # Nota: os metodos somente utilizados em callbacks ou utilizados somente por essa
  #       propria classe deverao ser privados (remover essa anotacao)
end