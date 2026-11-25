require 'test_helper'
require_relative 'finance/../../support/finance_factory'

# Botão Colunas: cada pessoa arruma a ordem e quais colunas aparecem, e fica salvo para ela.
class TableColumnsTest < ActionDispatch::IntegrationTest
  include FinanceFactory

  def setup
    @user = finance_user('Financeiro', email: 'financeiro@chasebrasil.com')
    Finance::Setup.ensure_profile!
    @user.reload
    @other = finance_user('Outra')
    @other.profiles << Profile.find_by(name: 'Financeiro')
    @key = '/financeiro/notas_fiscais|main'
  end

  def headers_of_table = css_select('table.pg-tbl thead th').map { |th| th.text.strip }.reject(&:empty?)

  test 'aplica a ordem e as colunas escolhidas, so para quem salvou' do
    finance_order(user: @user, payment_terms: '30').tap do |order|
      company = Company.new(legal_name: 'E', cnpj: '11.222.333/0001-81', street: 'R', number: '1', neighbourhood: 'B', city: 'BH', city_ibge_code: '3106200', state: 'MG', zip: '30000000')
      company.save!(validate: false)
      FiscalNote.create!(company: company, b2b_order: order, number: 9, series: 1, environment: :producao, status: :autorizada, total_value: 10, issued_at: Time.current)
    end
    sign_in @user
    get wholesale_fiscal_notes_path
    assert_select '[data-controller=pg-columns]'
    default = headers_of_table
    assert_includes default, 'Empresa'
    assert_not_includes default, 'Chave de acesso'

    items = JSON.parse(css_select('[data-controller=pg-columns]').first['data-pg-columns-items-value'])
    assert_equal({ 'k' => 'num', 'label' => 'Nº', 'on' => true, 'locked' => true, 'default' => true }, items.first)
    chave = items.find { |i| i['k'] == 'chave' }
    columns = ([chave.merge('on' => true)] + (items - [chave])).map do |i|
      { k: i['k'], on: %w[empresa num].include?(i['k']) ? false : i['on'] }
    end
    patch table_columns_path, params: { key: @key, columns: columns }, as: :json
    assert_response :no_content

    get wholesale_fiscal_notes_path
    cols = headers_of_table
    assert_equal ['Chave de acesso', 'Nº'], cols.first(2) # a principal (Nº) não some
    assert_not_includes cols, 'Empresa'
    assert_select '.pg-cols-dot'

    sign_out @user
    sign_in @other
    get wholesale_fiscal_notes_path
    assert_equal default, headers_of_table

    sign_out @other
    sign_in @user
    delete table_columns_path, params: { key: @key }, as: :json
    get wholesale_fiscal_notes_path
    assert_equal default, headers_of_table
  end

  test 'ignora coluna invalida e exige login' do
    patch table_columns_path, params: { key: @key, columns: [{ k: 'x' }] }, as: :json
    assert_response :unauthorized
    sign_in @user
    patch table_columns_path, params: { key: @key, columns: [{ k: 'a b<script>', on: true }] }, as: :json
    assert_response :unprocessable_content
    assert_equal 0, TableColumnPreference.count
  end

  test 'coluna nova da tela entra na posicao padrao' do
    table = HoneyTable.new({}, rows: [], cols: [{ k: :a, label: 'A', main: true }, { k: :b, label: 'B' }, { k: :c, label: 'C' }, { k: :d, label: 'D', hide: true }])
    table.apply_layout([['c', true], ['a', true]])
    assert_equal %i[c d a b], table.cols.map { |c| c[:k] } # nova entra logo depois da vizinha padrão
    assert_equal %i[c a b], table.visible_cols.map { |c| c[:k] }
  end
end
