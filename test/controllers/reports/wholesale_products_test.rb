require 'test_helper'
require_relative '../../support/finance_factory'

# Análise de produtos do atacado: curva ABC, parados e candidatos a outlet.
class Reports::WholesaleProductsTest < ActionDispatch::IntegrationTest
  include FinanceFactory

  def setup
    @admin = finance_user('Admin Produtos')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @company = Company.new(legal_name: 'Emissora', cnpj: '11.222.333/0001-81', street: 'R', number: '1', neighbourhood: 'B', city: 'BH',
                           city_ibge_code: '3106200', state: 'MG', zip: '30000000')
    @company.save!(validate: false)
    @n = 900
  end

  def sale(items, date)
    order = finance_order(user: @admin, price: 0, created_at: date)
    order.b2b_order_items.delete_all
    items.each { |name, qty, price| order.b2b_order_items.create!(sku: name.parameterize, name: name, quantity: qty, price: price) }
    FiscalNote.create!(company: @company, b2b_order: order, number: (@n += 1), series: 1, environment: :producao, status: :autorizada,
                       total_value: 1, issued_at: date, access_key: format('%044d', @n))
    order
  end

  test 'classifica a curva abc, acha parados e candidatos a outlet e ignora devolucao' do
    today = Date.current
    sale([['Legging Alpha - P', 10, 100], ['Top Beta - M', 2, 50]], today - 5)
    sale([['Legging Alpha - M', 5, 100], ['Short Gama - G', 1, 30]], today - 10)
    sale([['Jaqueta Velha - G', 4, 200]], today - 400)
    dev = sale([['Top Beta - M', 50, 50]], today - 3)
    dev.update_columns(replacement: true)

    report = Reports::WholesaleProducts.new(Reports::WholesaleSales.period('30d'))
    by = report.models.index_by { |m| m[:model] }
    assert_equal 'A', by['Legging Alpha'][:abc]
    assert_equal 15, by['Legging Alpha'][:pieces]
    assert_equal 2, by['Top Beta'][:pieces], 'pedido de devolução não conta'
    assert_includes %w[B C], by['Short Gama'][:abc]
    assert_equal 'outlet', by['Jaqueta Velha'][:status]
    assert_match 'Sem venda há', by['Jaqueta Velha'][:reason]
    assert_equal 'ativo', by['Legging Alpha'][:status]

    orders = Reports::WholesaleProducts.new(Reports::WholesaleSales.period('30d'), basis: 'pedidos')
    assert_equal 'pedidos', orders.basis

    sign_in @admin
    get reports_wholesale_products_path(periodo: '30d')
    assert_response :success
    assert_select '.rpt-pareto'
    assert_select '.rpt-outlet li', 1
    get reports_wholesale_products_path(base: 'pedidos')
    assert_response :success
  end

  test 'quem nao tem a permissao nao abre' do
    sign_in finance_user('Sem Relatorio')
    get reports_wholesale_products_path
    assert_redirected_to root_path
  end
end
