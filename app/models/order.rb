class Order < ApplicationRecord
  enum kinds: [:lagoa_seca, :bh_shopping, :rj]
  # Callbacks
  # Associacoes
  has_many :order_items
  # Validacoes
  def obtain_order_and_verify_contact(kind, shopify_order_id)
    order = Order.find_by(shopify_order_id:)

    return unless order
    tiny_order_id = order.tiny_order_id

    case kind
    when 'bh_shopping'
      token = ENV.fetch('TOKEN_TINY_PRODUCTION_BH_SHOPPING')
    when 'lagoa_seca'
      token = ENV.fetch('TOKEN_TINY_PRODUCTION')
    when 'rj'
      token = ENV.fetch('TOKEN_TINY_PRODUCTION_RJ')
    else
      raise ArgumentError, "Tipo de cliente desconhecido: #{kind}"
    end

    response = Tiny::Orders.obtain_order(token, tiny_order_id)
    cliente = response.dig('pedido', 'cliente')

    if cliente.nil?
      puts "Cliente não encontrado na resposta do pedido #{tiny_order_id}"
      nil
    end

    fone = cliente['fone'].to_s.strip
    email = cliente['email'].to_s.strip

    if fone.empty? && email.empty?
      puts "Cliente #{tiny_order_id} #{cliente['nome']} não possui telefone nem e-mail."
      false
    else
      puts "Cliente #{tiny_order_id} #{cliente['nome']} possui #{'telefone' unless fone.empty?}#{' e ' unless fone.empty? || email.empty?}#{'e-mail' unless email.empty?}."
      true
    end
  end

  # Escopos
  # Metodos estaticos
  # Metodos publicos
  # Metodos GET
  # Metodos SET

  # Nota: os metodos somente utilizados em callbacks ou utilizados somente por essa
  #       propria classe deverao ser privados (remover essa anotacao)
end
