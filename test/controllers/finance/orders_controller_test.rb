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

  test 'boleto mostra um quadradinho por parcela com o prazo e os dados para a baixa' do
    @boleto.payments.first.update!(paid_at: Date.current, paid_by: @finance)
    sign_in @finance
    get wholesale_fiscal_notes_path(mes: 'todos')
    chips = css_select('[data-fin-parcel]')
    assert_equal %w[30 60 90], chips.map { |c| c.text.strip }
    info = JSON.parse(chips.first['data-fin-parcel'])
    assert_equal 'pago', info['st']
    assert_equal unpay_finance_payment_path(@boleto.payments.first), info['unpay']
    assert_equal 'pendente', JSON.parse(chips.last['data-fin-parcel'])['st']
    assert_match 'var canPay = true', response.body
    assert_no_match 'pay_many', response.body
  end

  test 'nota cancelada mostra nao enviado no status do pedido, mesmo com o pedido enviado' do
    @pix.update_columns(status: B2bOrder.statuses[:enviado])
    @pix_note.update_columns(status: FiscalNote.statuses[:cancelada])
    new_note = FiscalNote.create!(company: @pix_note.company, b2b_order: @pix, number: 503, series: 1, environment: :producao, status: :autorizada,
                                  total_value: 150, issued_at: Time.current, access_key: format('%044d', 503))
    sign_in @finance
    get wholesale_fiscal_notes_path(mes: 'todos')
    assert_select 'td', text: /Não enviado/, count: 1
    get wholesale_fiscal_notes_path(mes: 'todos', ost: 'enviado')
    assert_select '.row-select-checkbox', count: 1
    assert_select '.row-select-checkbox[data-id=?]', new_note.id.to_s
    get wholesale_fiscal_notes_path(mes: 'todos', ost: 'nao_enviado')
    assert_select '.row-select-checkbox', count: 1
    assert_select '.row-select-checkbox[data-id=?]', @pix_note.id.to_s
  end

  test 'baixar planilha leva todas as notas do filtro com todas as colunas' do
    @pix.update_columns(status: B2bOrder.statuses[:enviado])
    sign_in @finance
    get export_wholesale_fiscal_notes_path(mes: 'todos')
    assert_response :success
    assert_equal 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', response.media_type
    sheet = RubyXL::Parser.parse_buffer(response.body)[0]
    rows = sheet.sheet_data.rows.compact.map { |row| row.cells.map { |c| c&.value } }
    assert_includes rows[0], 'Status do pedido'
    assert_includes rows[0], 'Chave de acesso'
    assert_not_includes rows[0], 'Recebimento'
    assert_equal 3, rows.size
    parcel_col = rows[0].index('Parcelas (vencimento, valor, situação)')
    assert(rows[1..].any? { |r| r[parcel_col].to_s.start_with?('30d ') })

    get export_wholesale_fiscal_notes_path(mes: 'todos', ost: 'enviado')
    rows = RubyXL::Parser.parse_buffer(response.body)[0].sheet_data.rows.compact
    assert_equal 2, rows.size
  end

  test 'sem exportar nao baixa planilha' do
    sign_in @viewer
    get export_wholesale_fiscal_notes_path(mes: 'todos')
    assert_redirected_to root_path
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
    assert_match 'var canPay = false', response.body
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

  test 'financeiro aumenta e diminui as parcelas do boleto sem mexer nas pagas' do
    sign_in @finance
    first = @boleto.payments.first
    first.update!(paid_at: Date.new(2026, 11, 20), paid_by: @finance)
    get edit_finance_order_path(@boleto)
    assert_select '.fin-terms input[name=payment_terms][value=?]', '30 60 90'

    patch terms_finance_order_path(@boleto), params: { payment_terms: '30 60 90 120' }
    assert_redirected_to edit_finance_order_path(@boleto, return_to: wholesale_fiscal_notes_path)
    payments = @boleto.payments.reload
    assert_equal [1, 2, 3, 4], payments.map(&:number)
    assert_equal first.id, payments.first.id
    assert_equal [100.0, 66.66, 66.66, 66.68], payments.map { |p| p.amount.to_f }
    assert_equal @boleto.grand_total, payments.sum(&:amount)
    assert_equal '30 60 90 120', @boleto.reload.payment_terms

    patch terms_finance_order_path(@boleto), params: { payment_terms: '30 45' }
    assert_equal [100.0, 200.0], @boleto.payments.reload.map { |p| p.amount.to_f }
    assert_equal first.due_date, @boleto.payments.first.due_date
  end

  test 'prazos invalidos ou pedido que nao e boleto nao mudam' do
    sign_in @finance
    @boleto.payments.first.update!(paid_at: Date.current)
    @boleto.payments.second.update!(paid_at: Date.current)
    patch terms_finance_order_path(@boleto), params: { payment_terms: '30' }
    assert_match 'pelo menos 2', flash[:alert]
    patch terms_finance_order_path(@boleto), params: { payment_terms: '60 30' }
    assert_match 'precisam crescer', flash[:alert]
    patch terms_finance_order_path(@boleto), params: { payment_terms: 'abc' }
    assert_equal '30 60 90', @boleto.reload.payment_terms

    patch terms_finance_order_path(@pix), params: { payment_terms: '30 60' }
    assert_match 'boleto', flash[:alert]
    assert_empty @pix.payments.reload
  end

  test 'quem so ve nao muda as parcelas' do
    sign_in @viewer
    get edit_finance_order_path(@boleto)
    assert_select '.fin-terms', count: 0
    patch terms_finance_order_path(@boleto), params: { payment_terms: '30' }
    assert_redirected_to root_path
    assert_equal '30 60 90', @boleto.reload.payment_terms
  end

  test 'parcela de pedido cancelado nao recebe baixa' do
    sign_in @finance
    @boleto.update_column(:status, B2bOrder.statuses[:cancelado])
    patch pay_finance_payment_path(@boleto.payments.first)
    assert_nil @boleto.payments.first.reload.paid_at
  end
end
