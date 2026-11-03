require 'test_helper'
require_relative '../support/nfe_company_factory'

class OperationNaturesControllerTest < ActionDispatch::IntegrationTest
  include NfeCompanyFactory

  def setup
    @admin = User.create!(name: 'Admin Naturezas', email: 'admin_naturezas@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @company = create_nfe_company
    sign_in @admin
  end

  def nature_params(overrides = {})
    { company_id: @company.id, description: 'Venda Online', kind: 'sale', default_for_kind: '1', purpose: '1',
      final_consumer: '1', cfop: '?.102', cfop_interstate_non_contributor: '6108', icms_situation: '00',
      icms_rate: '18', difal: '1', pis_cst: '01', pis_rate: '1.65', cofins_cst: '01', cofins_rate: '7.6',
      exclude_icms_from_pis_cofins_base: '1', notes: 'Pedido {pedido}', active: '1',
      uf_rates: { 'SP' => { internal: '18', fcp: '0' }, 'RJ' => { internal: '20', fcp: '2' } } }.merge(overrides)
  end

  test 'creates a nature like in Tiny, normalizing the CFOP' do
    get new_operation_nature_path
    assert_response :success

    assert_difference('OperationNature.count', 1) { post operation_natures_path, params: { operation_nature: nature_params } }
    assert_redirected_to operation_natures_path

    nature = OperationNature.last
    assert_equal '?102', nature.cfop
    assert_equal({ 'internal' => '20', 'fcp' => '2' }, nature.uf_rates['RJ'])
    assert_equal BigDecimal('2'), nature.rates_for('RJ')[:fcp]
    assert_equal '5102', nature.cfop_for(company_state: 'MG', recipient_state: 'MG')
    assert_equal '6102', nature.cfop_for(company_state: 'MG', recipient_state: 'SP')
    assert_equal '6108', nature.cfop_for(company_state: 'MG', recipient_state: 'SP', non_contributor: true)

    get operation_natures_path
    assert_select 'td .pg-txt', text: 'Venda Online'
  end

  test 'Simples Nacional codes are refused for a Regime Normal company' do
    post operation_natures_path, params: { operation_nature: nature_params(icms_situation: '102') }
    assert_response :unprocessable_entity
    assert_select '.form-error-box', text: /CST/
  end

  test 'only one default per kind' do
    first = create_sale_nature(@company)
    post operation_natures_path, params: { operation_nature: nature_params(description: 'Venda Site 2') }
    refute first.reload.default_for_kind?
    assert OperationNature.find_by(description: 'Venda Site 2').default_for_kind?
  end

  test 'edits and deletes' do
    nature = create_sale_nature(@company)
    patch operation_nature_path(nature), params: { operation_nature: { icms_rate: '20.5' } }
    assert_equal BigDecimal('20.5'), nature.reload.icms_rate

    assert_difference('OperationNature.count', -1) { delete operation_nature_path(nature) }
  end
end
