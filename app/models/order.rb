class Order < ApplicationRecord
  enum kinds: [:lagoa_seca,
               :bh_shopping,
               :rj,
               :eldorado_sp,
               :fortaleza_rio_mar,
               :porto_alegre_bourbon,
               :shopping_analia_franco,
               :iguatemi_campinas,
               :":log+"]

  after_initialize do
    self.iglu_payments ||= []
  end

  belongs_to :location, optional: true
  belongs_to :customer, optional: true
  has_many :order_items

  def obtain_order_and_verify_contact(kind, shopify_order_id)
    order = Order.find_by(shopify_order_id:)
    return unless order

    tiny_order_id = order.tiny_order_id

    token = case kind
            when 'bh_shopping'
              ENV.fetch('TOKEN_TINY_PRODUCTION_BH_SHOPPING')
            when 'lagoa_seca'
              ENV.fetch('TOKEN_TINY_PRODUCTION')
            when 'rj'
              ENV.fetch('TOKEN_TINY_PRODUCTION_RJ')
            else
              raise ArgumentError, "Tipo de cliente desconhecido: #{kind}"
            end

    response = Tiny::Orders.obtain_order(token, tiny_order_id)
    cliente = response.dig('pedido', 'cliente')

    if cliente.nil?
      puts "Cliente não encontrado na resposta do pedido #{tiny_order_id}"
      return nil
    end

    fone  = cliente['fone'].to_s.strip
    email = cliente['email'].to_s.strip

    if fone.empty? && email.empty?
      puts "Cliente #{tiny_order_id} #{cliente['nome']} não possui telefone nem e-mail."
      false
    else
      puts "Cliente #{tiny_order_id} #{cliente['nome']} possui #{'telefone' unless fone.empty?}#{' e ' unless fone.empty? || email.empty?}#{'e-mail' unless email.empty?}."
      true
    end
  end
end