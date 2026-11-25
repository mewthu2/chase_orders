require 'test_helper'
require_relative '../support/finance_factory'

# Pedido de devolução do atacado: criado a partir do pedido original, com as peças escolhidas e sem cobrança.
class B2bOrderReplacementsTest < ActionDispatch::IntegrationTest
  include FinanceFactory

  KEY = '31261125405327000255550010000157121030566741'.freeze

  def setup
    @admin = finance_user('Admin Devolucao')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @original = finance_order(user: @admin, price: 200, payment_method: 'boleto', payment_terms: '30 60', salesperson_name: 'Dani')
    @original.b2b_order_items.create!(sku: 'SKU2', name: 'Moletom', quantity: 3, price: 280)
    @original.update_columns(freight_service: 'SEDEX CORREIOS LOG+')
  end

  test 'cria o pedido de devolucao vinculado com as pecas escolhidas, sem cobranca' do
    sign_in @admin
    get edit_b2b_order_path(@original)
    assert_select "a[href='#{new_replacement_b2b_order_path(@original)}']"
    get new_replacement_b2b_order_path(@original)
    assert_response :success

    item = @original.b2b_order_items.find_by(sku: 'SKU2')
    post replacement_b2b_order_path(@original), params: { qty: { item.id => 5 } }
    assert_match 'só 3', flash[:alert]
    post replacement_b2b_order_path(@original), params: { qty: {} }
    assert_match 'pelo menos uma', flash[:alert]

    assert_difference -> { B2bOrder.count }, 1 do
      post replacement_b2b_order_path(@original), params: { qty: { item.id => 2 }, original_nfe_key: KEY, notes: 'Zíper quebrado' }
    end
    order = B2bOrder.last
    assert_redirected_to edit_b2b_order_path(order)
    assert order.replacement?
    assert_equal @original, order.replacement_of
    assert_equal @original.client, order.client
    assert_equal KEY, order.original_nfe_key
    assert_equal [['SKU2', 2]], order.b2b_order_items.map { |i| [i.sku, i.quantity] }
    assert_equal 0, order.grand_total.to_i
    assert_empty order.payments
    assert order.aberto?
    assert_match 'Zíper', order.notes
  end

  test 'aba nota fiscal marca a devolucao e confere as chaves; a configuracao escolhe empresa e natureza' do
    sign_in @admin
    patch replacement_b2b_order_path(@original), params: { replacement: { replacement: '1', original_nfe_key: '123' } }
    assert_match 'inválida', flash[:alert]
    refute @original.reload.replacement?

    patch replacement_b2b_order_path(@original), params: { replacement: { replacement: '1', original_nfe_key: KEY } }
    assert @original.reload.replacement?
    assert_equal KEY, @original.original_nfe_key

    company = Company.new(legal_name: 'CHASE 02', trade_name: 'Chase 02 - Contagem', cnpj: '11.222.333/0001-81', street: 'R', number: '1',
                          neighbourhood: 'B', city: 'Contagem', city_ibge_code: '3118601', state: 'MG', zip: '32000000')
    company.save!(validate: false)
    nature = company.operation_natures.create!(description: 'ATACADO - MERCADORIA EM SUBSTITUICAO POR DEFEITO', kind: :sale, cfop: '?102',
                                               icms_situation: '102', pis_cst: '49', cofins_cst: '49')
    setting = B2bSetting.current
    assert_equal nature, setting.nature_for(@original)
    setting.update_columns(return_issuer_company_id: company.id)
    assert_equal company, setting.issuer(@original)
    refute_equal company, setting.issuer(B2bOrder.new(kind: :sale))

    get edit_b2b_order_path(@original, tab: 'nota')
    assert_select '.rp-card.is-on'
    patch replacement_b2b_order_path(@original), params: { replacement: { replacement: '0', original_nfe_key: KEY } }
    refute @original.reload.replacement?
  end
end
