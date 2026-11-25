# Pedidos de atacado para os testes do Financeiro.
module FinanceFactory
  def finance_user(name = 'Digitador', email: nil)
    User.create!(name: name, email: email || "#{name.parameterize}_#{SecureRandom.hex(3)}@example.com", password: 'password123')
  end

  def finance_client
    @finance_client ||= Client.create!(responsible_name: 'Lojista Fin', registration: '25.405.327/0001-74')
  end

  # Pedido de venda com um item de `price` e o frete dado.
  def finance_order(user:, price: 300, freight: 0, payment_method: 'boleto', payment_terms: nil, created_at: Time.current, **attrs)
    o = B2bOrder.new({ kind: :sale, user: user, client: finance_client, payment_method: payment_method, payment_terms: payment_terms,
                       freight_value: freight, created_at: created_at }.merge(attrs))
    o.b2b_order_items.build(sku: 'SKU1', name: 'Legging', quantity: 1, price: price)
    o.save!(validate: false)
    o
  end
end
