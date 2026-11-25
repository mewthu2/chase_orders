require 'test_helper'
require_relative '../../support/finance_factory'

# Financeiro › Notas Fiscais: as notas do atacado com o status do pedido, o recebimento e a baixa das parcelas.
class Finance::FiscalNotesTest < ActionDispatch::IntegrationTest
  include FinanceFactory

  def setup
    @finance = finance_user('Financeiro', email: 'financeiro@chasebrasil.com')
    Finance::Setup.ensure_profile!
    @finance.reload
    @viewer = finance_user('So Ve')
    profile = Profile.create!(name: 'Só vê financeiro')
    profile.screen_actions = { 'finance_orders' => 'V' }
    profile.save!
    @viewer.profiles << profile
    @boleto = finance_order(user: @finance, price: 300, payment_terms: '30 60 90', salesperson_name: 'Ana')
    @pix = finance_order(user: @finance, price: 150, payment_method: 'pix')
    company = Company.new(legal_name: 'Emissora', cnpj: '11.222.333/0001-81', street: 'R', number: '1', neighbourhood: 'B', city: 'BH',
                          city_ibge_code: '3106200', state: 'MG', zip: '30000000')
    company.save!(validate: false)
    @boleto_note = finance_note(company, @boleto, 501)
    @pix_note = finance_note(company, @pix, 502)
  end

  def finance_note(company, order, number)
    FiscalNote.create!(company: company, b2b_order: order, number: number, series: 1, environment: :producao, status: :autorizada,
                       total_value: order.grand_total, issued_at: Time.current, access_key: format('%044d', number))
  end

  test 'a tela antiga de pedidos e a de notas do atacado levam para as notas do financeiro' do
    sign_in @finance
    get '/financeiro/pedidos'
    assert_redirected_to '/financeiro/notas_fiscais'
    get '/atacado/notas_fiscais?mes=todos'
    assert_redirected_to '/financeiro/notas_fiscais?mes=todos'
  end

  test 'lista mostra status do pedido e recebimento e filtra pelos dois' do
    @pix.update_columns(status: B2bOrder.statuses[:enviado])
    sign_in @finance
    get wholesale_fiscal_notes_path(mes: 'todos')
    assert_response :success
    assert_select 'th', text: /Status do pedido/
    assert_select 'th', text: /Recebimento/
    assert_select 'td', text: /Enviado/
    assert_select 'td', text: /A receber/
    assert_select '.row-select-checkbox[data-open=?]', '3'
    assert_match 'Dar baixa em', response.body

    get wholesale_fiscal_notes_path(mes: 'todos', ost: 'enviado')
    assert_select '.row-select-checkbox', count: 1
    get wholesale_fiscal_notes_path(mes: 'todos', rec: 'pago')
    assert_select '.row-select-checkbox[data-id=?]', @pix_note.id.to_s
    assert_select '.row-select-checkbox', count: 1
    @boleto.payments.first.update!(due_date: Date.current - 1)
    get wholesale_fiscal_notes_path(mes: 'todos', rec: 'vencido')
    assert_select '.row-select-checkbox[data-id=?]', @boleto_note.id.to_s
    get wholesale_fiscal_notes_path(mes: 'todos', rec: 'pendente')
    assert_select '.row-select-checkbox', count: 0
  end

  test 'quem tem so atacado nao ve mais as notas do atacado' do
    seller = finance_user('Vendedora')
    profile = Profile.create!(name: 'Atacado')
    profile.screen_actions = { 'b2b_orders' => 'VCEXDP' }
    profile.save!
    seller.profiles << profile
    sign_in seller.reload
    get wholesale_fiscal_notes_path
    assert_redirected_to root_path
  end

  test 'baixa em lote pelas notas marcadas pega as parcelas pendentes dos pedidos delas' do
    sign_in @finance
    p1, p2, p3 = @boleto.payments.to_a
    p1.update!(paid_at: Date.new(2026, 1, 1))
    patch pay_many_finance_payments_path, params: { note_ids: "#{@boleto_note.id},#{@pix_note.id}", paid_at: '2026-11-21',
                                                    return_to: '/financeiro/notas_fiscais?mes=todos' }
    assert_redirected_to '/financeiro/notas_fiscais?mes=todos'
    assert_equal Date.new(2026, 1, 1), p1.reload.paid_at
    assert_equal [Date.new(2026, 11, 21)] * 2, [p2.reload.paid_at, p3.reload.paid_at]
    assert_equal @finance, p2.paid_by
  end

  test 'baixa em lote pode usar a data do vencimento' do
    sign_in @finance
    patch pay_many_finance_payments_path, params: { note_ids: @boleto_note.id.to_s, on_due: '1' }
    assert(@boleto.payments.reload.all? { |p| p.paid_at == p.due_date })
  end

  test 'tela do pedido: baixa de uma parcela e desfazer' do
    sign_in @finance
    back = edit_finance_order_path(@boleto, return_to: '/financeiro/notas_fiscais')
    get back
    assert_response :success
    assert_select 'table.fin-parcels tbody tr', count: 3
    payment = @boleto.payments.first
    patch pay_finance_payment_path(payment), params: { paid_at: '2026-11-20', return_to: back }
    assert_redirected_to back
    assert_equal Date.new(2026, 11, 20), payment.reload.paid_at
    assert_equal @finance, payment.paid_by
    patch unpay_finance_payment_path(payment), params: { return_to: 'https://fora.com/x' }
    assert_redirected_to wholesale_fiscal_notes_path
    assert_nil payment.reload.paid_at
    assert_nil payment.paid_by
  end

  test 'quem so ve abre as notas e o pedido mas nao da baixa' do
    sign_in @viewer
    get wholesale_fiscal_notes_path(mes: 'todos')
    assert_response :success
    assert_no_match 'Dar baixa em', response.body
    get edit_finance_order_path(@boleto)
    assert_response :success
    assert_select 'form.fin-pay-one', count: 0
    patch pay_finance_payment_path(@boleto.payments.first)
    assert_redirected_to root_path
    assert_nil @boleto.payments.first.reload.paid_at
  end

  test 'so com o financeiro baixa XML e DANFE da nota e o pedido abre o recebimento' do
    @boleto_note.xml.attach(io: StringIO.new('<nfeProc>501</nfeProc>'), filename: 'n.xml', content_type: 'application/xml')
    sign_in @finance
    get wholesale_fiscal_notes_path(mes: 'todos')
    assert_select "a[href=?]", xml_wholesale_fiscal_note_path(@boleto_note)
    assert_select "a[href^=?]", edit_finance_order_path(@boleto)
    assert_select "a[href*=?]", "tab=nota", count: 0
    get xml_wholesale_fiscal_note_path(@boleto_note)
    assert_response :success
    assert_equal '<nfeProc>501</nfeProc>', response.body
    get xml_wholesale_fiscal_note_path(@pix_note)
    assert_redirected_to wholesale_fiscal_notes_path
  end

  test 'parcela de pedido cancelado nao recebe baixa' do
    sign_in @finance
    @boleto.update_column(:status, B2bOrder.statuses[:cancelado])
    patch pay_finance_payment_path(@boleto.payments.first)
    assert_nil @boleto.payments.first.reload.paid_at
  end
end
