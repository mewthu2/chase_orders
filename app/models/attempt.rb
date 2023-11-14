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
           attempts.error LIKE :valor OR
           attempts.message LIKE :valor OR
           attempts.id LIKE :valor', valor: "#{value}%")
  end

  add_scope :by_status do |status, kinds|
    if status == 'error' || 'fail'
      case kinds
      when 'create_correios_order'
        where.not(tiny_order_id: Attempt.where(kinds: :create_correios_order, status: :success).pluck(:tiny_order_id).uniq)
      when 'send_xml'
        where.not(tiny_order_id: Attempt.where(kinds: :send_xml, status: :success).pluck(:tiny_order_id).uniq)
      when 'emission_invoice'
        where.not(tiny_order_id: Attempt.where(kinds: :emission_invoice, status: :success).pluck(:tiny_order_id).uniq)
      when 'get_tracking'
        where.not(tiny_order_id: Attempt.where(kinds: :get_tracking, status: :success).pluck(:tiny_order_id).uniq)
      end
    end
  end
  # Metodos estaticos
  # Metodos publicos
  # Metodos GET
  # Metodos SET

  # Nota: os metodos somente utilizados em callbacks ou utilizados somente por essa
  #       propria classe deverao ser privados (remover essa anotacao)
end
