# Nó de pedido no formato da consulta GraphQL do Nfe::ShopifyOrder, com os atributos que o checkout grava.
module ShopifyOrderFactory
  module_function

  def node(overrides = {})
    {
      'legacyResourceId' => '6100000000001', 'name' => '#1001', 'createdAt' => '2026-10-27T10:00:00-03:00',
      'cancelledAt' => nil, 'displayFinancialStatus' => 'PAID', 'email' => 'maria@example.com', 'phone' => nil,
      'paymentGatewayNames' => ['Mercado Pago'],
      'shippingAddress' => { 'name' => 'Maria Cliente', 'company' => nil, 'address1' => 'Rua das Flores, 10',
                             'address2' => 'Centro', 'city' => 'Belo Horizonte', 'provinceCode' => 'MG',
                             'zip' => '30140-071', 'phone' => '31999998888' },
      'billingAddress' => nil,
      'localizedFields' => { 'nodes' => [] },
      'customAttributes' => [
        { 'key' => 'additional_cpf_cnpj', 'value' => '52998224725' },
        { 'key' => 'shipping_street_name', 'value' => 'Rua das Flores' },
        { 'key' => 'shipping_street_number', 'value' => '10' },
        { 'key' => 'shipping_street_complement', 'value' => 'Apto 2' },
        { 'key' => 'shipping_neighborhood', 'value' => 'Funcionários' },
        { 'key' => 'shipping_city', 'value' => 'Belo Horizonte' },
        { 'key' => 'shipping_province', 'value' => 'MG' },
        { 'key' => 'payment_type', 'value' => 'credit_card' },
        { 'key' => 'payment_method', 'value' => 'master' },
        { 'key' => 'payment_installment', 'value' => '3' }
      ],
      'lineItems' => { 'nodes' => [
        { 'sku' => 'SKU-1', 'name' => 'Camiseta P', 'quantity' => 2, 'currentQuantity' => 2,
          'originalUnitPriceSet' => { 'shopMoney' => { 'amount' => '100.0' } },
          'discountAllocations' => [{ 'allocatedAmountSet' => { 'shopMoney' => { 'amount' => '20.0' } } }] },
        { 'sku' => 'SKU-2', 'name' => 'Short M', 'quantity' => 1, 'currentQuantity' => 1,
          'originalUnitPriceSet' => { 'shopMoney' => { 'amount' => '50.0' } }, 'discountAllocations' => [] }
      ] },
      'shippingLines' => { 'nodes' => [{ 'title' => 'SEDEX', 'discountedPriceSet' => { 'shopMoney' => { 'amount' => '15.0' } } }] }
    }.merge(overrides)
  end

  def attribute(node, key, value)
    node.merge('customAttributes' => node['customAttributes'].reject { |a| a['key'] == key } + [{ 'key' => key, 'value' => value }])
  end
end
