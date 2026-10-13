class Attempt < ApplicationRecord
  enum status: [:fail, :error, :success, :processing]
  enum kinds: [:create_correios_order, :send_xml, :emission_invoice, :get_tracking, :create_note_tiny2, :emission_invoice_tiny2, :transfer_tiny_to_shopify_order, :sync_correios_stock, :create_correios_order_tiny2, :send_xml_tiny2, :get_tracking_tiny2]

  B2C_KINDS = %w[create_correios_order send_xml emission_invoice get_tracking].freeze
  B2B_KINDS = %w[create_correios_order_tiny2 send_xml_tiny2 emission_invoice_tiny2 get_tracking_tiny2].freeze
  # Conta da reserva de estoque de cada tipo de criação de pedido no Correios Log.
  RESERVATION_ACCOUNTS = { 'create_correios_order' => :b2c, 'create_correios_order_tiny2' => :b2b }.freeze

  # Callbacks
  after_commit :release_stock_reservation, on: [:create, :update]
  # Associacoes

  # Validacoes
  def self.retrigger_shopify_order(shopify_order_id)
    attempt = Attempt.by_shopify_order_id(shopify_order_id).first
    return puts 'Attempt não encontrado.' unless attempt

    tiny_order_id = attempt.tiny_order_id
    kind = attempt.tracking.match(/kind:(\w+)/)[1] rescue nil

    return puts 'Kind não encontrado no tracking.' unless kind
    return puts 'tiny_order_id não encontrado.' unless tiny_order_id

    result = CreateShopifyOrdersFromTinyJob.perform_now(kind, tiny_order_id)

    new_shopify_order_id = result['id'] rescue nil
    return puts 'Erro ao criar pedido Shopify.' unless new_shopify_order_id

    attempt.destroy

    order = Order.find_by(tiny_order_id:)
    if order
      order.update(shopify_order_id: new_shopify_order_id)
      puts "Pedido atualizado com o novo shopify_order_id: #{new_shopify_order_id}"
    else
      puts "Order não encontrada com tiny_order_id: #{tiny_order_id}"
    end
  end
  # Escopos
  add_scope :search do |value|
    where('attempts.tiny_order_id LIKE :valor OR
           attempts.order_correios_id LIKE :valor OR
           attempts.error LIKE :valor OR
           attempts.message LIKE :valor OR
           attempts.id LIKE :valor', valor: "#{value}%")
  end

  add_scope :by_shopify_order_id do |value|
    where('tracking LIKE ?', "%#{value}%")
  end
  # Metodos estaticos
  # Metodos publicos
  # Metodos GET
  # Metodos SET

  # Nota: os metodos somente utilizados em callbacks ou utilizados somente por essa
  #       propria classe deverao ser privados (remover essa anotacao)

  private

  # Pedido criado no Correios Log já está reservado no WMS: sai da reserva de estoque na hora,
  # sem esperar a próxima atualização da fila.
  def release_stock_reservation
    account = RESERVATION_ACCOUNTS[kinds]
    return unless account && tiny_order_id.present?
    return unless success? || order_correios_id.to_i.positive?

    StockReservation.where(account:, tiny_order_id: tiny_order_id.to_s).delete_all
  end
end
