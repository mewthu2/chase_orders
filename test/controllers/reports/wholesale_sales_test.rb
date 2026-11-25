require 'test_helper'
require_relative '../../support/finance_factory'

# Adm › Dashboards e relatórios › Vendas Atacado: NF-e de venda autorizada em produção = venda.
class Reports::WholesaleSalesTest < ActionDispatch::IntegrationTest
  include FinanceFactory

  def setup
    @admin = finance_user('Admin Rel')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @common = finance_user('Comum Rel')
    @company = Company.new(legal_name: 'Emissora', cnpj: '11.222.333/0001-81', street: 'R', number: '1', neighbourhood: 'B', city: 'BH',
                           city_ibge_code: '3106200', state: 'MG', zip: '30000000')
    @company.save!(validate: false)
    @day = Date.new(2026, 11, 10)
  end

  def note(order, number, issued:, status: :autorizada, environment: :producao, value: nil, role: nil)
    FiscalNote.create!(company: @company, b2b_order: order, number: number, series: 1, environment: environment, status: status, role: role,
                       total_value: value || order.grand_total, issued_at: issued, access_key: format('%044d', number))
  end

  test 'conta so as notas de venda autorizadas em producao do periodo e compara com o anterior' do
    a = finance_order(user: @admin, price: 1000)
    a.b2b_order_items.first.update_columns(name: 'TAILOR V OLIVE - P', quantity: 4, price: 250)
    b = finance_order(user: @admin, price: 500)
    note(a, 1, issued: @day.in_time_zone.change(hour: 10), value: 1000)
    note(b, 2, issued: @day.in_time_zone.change(hour: 11), value: 500)
    note(b, 3, issued: @day.in_time_zone, status: :cancelada, value: 500)
    note(b, 4, issued: @day.in_time_zone, environment: :homologacao, value: 999)
    note(b, 5, issued: @day.in_time_zone, role: 'remessa', value: 777)
    note(a, 6, issued: (@day << 1).in_time_zone, value: 600)

    report = Reports::WholesaleSales.new(Reports::WholesaleSales.period('2026-11', today: @day))
    assert_equal 1500.0, report.current[:revenue]
    assert_equal 2, report.current[:notes]
    assert_equal 750.0, report.current[:ticket]
    assert_equal 5, report.current[:pieces]
    assert_equal 1, report.cancelled[:count]
    assert_in_delta 1.5, report.delta(:revenue), 0.001 # 1500 contra 600
    assert_equal 1500.0, report.timeline.find { |p| p[:date] == @day }[:value]
    assert_equal 30, report.timeline.size
    assert_equal 'TAILOR V OLIVE', report.top_products.first[:label]
    assert_equal 4, report.top_products.first[:pieces]
    assert_equal 600.0, report.monthly_trend[-2][:value]
  end

  test 'tela abre para quem tem a permissao e aparece no menu do adm' do
    finance_order(user: @admin, price: 300).tap { |o| note(o, 10, issued: Time.current) }
    sign_in @admin
    get reports_wholesale_sales_path
    assert_response :success
    assert_match 'Faturamento', response.body
    assert_select 'svg.rpt-svg'
    assert_select '.rpt-bars li', minimum: 1
    get reports_wholesale_sales_path(periodo: '12m')
    assert_response :success
    get reports_wholesale_sales_path(periodo: 'ano-2026')
    assert_response :success
    ids = Navigation.flatten(Navigation.for(@admin)).map { |e| e[:item][:id] }
    assert_includes ids, 'rel-vendas-atacado'
  end

  test 'intervalo do calendario: por dia ate dois meses, por mes acima, comparando com os mesmos dias antes' do
    short = Reports::WholesaleSales.period('2026-11-03..2026-11-20', today: @day)
    assert_equal Date.new(2026, 11, 3)..Date.new(2026, 11, 20), short.range
    assert_equal Date.new(2026, 10, 16)..Date.new(2026, 11, 2), short.previous
    assert_equal :day, short.granularity
    assert_equal '03/11/2026 a 20/11/2026', short.label
    assert_equal :month, Reports::WholesaleSales.period('2026-01-01..2026-11-20').granularity

    o = finance_order(user: @admin, price: 300)
    note(o, 20, issued: Time.zone.local(2026, 11, 5, 10))
    note(o, 21, issued: Time.zone.local(2026, 11, 25, 10), value: 999)
    assert_equal 300.0, Reports::WholesaleSales.new(short).current[:revenue]

    sign_in @admin
    get reports_wholesale_sales_path(periodo: '2026-11-03..2026-11-20')
    assert_response :success
    assert_select '#rptPeriodo option[selected][value=?]', '2026-11-03..2026-11-20'
    assert_select '.pg-month[data-controller=date-range] .pg-cal-btn'
  end

  test 'sem permissao nao entra nem pelo link' do
    sign_in @common
    get reports_wholesale_sales_path
    assert_redirected_to root_path
  end
end
