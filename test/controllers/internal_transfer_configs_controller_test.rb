require 'test_helper'
require_relative '../support/nfe_company_factory'

# Transferência de Estoque → Configurações: aprovadores e, para a nota das remessas, a loja e a natureza de cada empresa.
class InternalTransferConfigsControllerTest < ActionDispatch::IntegrationTest
  include NfeCompanyFactory

  def setup
    @admin = User.create!(name: 'Admin', email: 'admin_itc@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @lagoa = Location.create!(slug: 'lagoa_seca', name: 'Lagoa Seca', shopify_location_id: '111')
    @bh = Location.create!(slug: 'bh_shopping', name: 'BH Shopping', shopify_location_id: '222')
    @company = create_nfe_company(tax_regime: 3)
    @other = create_nfe_company(legal_name: 'Chase Lagoa Ltda', cnpj: '45.723.174/0001-10', state_registration: '87654321', tax_regime: 3)
    @standard = @company.operation_natures.create!(description: 'Transferência padrão', kind: :transfer, cfop: '?152', final_consumer: false,
                                                    icms_situation: '41', pis_cst: '49', cofins_cst: '49')
    @shared = @other.operation_natures.create!(description: 'Transferência entre Filiais', kind: :transfer, cfop: '?152', final_consumer: false,
                                                icms_situation: '00', icms_rate: 18, pis_cst: '01', cofins_cst: '01')
    simples_company = create_nfe_company(legal_name: 'Loja Simples Ltda', cnpj: '25.405.327/0001-74', state_registration: '11122233', tax_regime: 1)
    @simples = simples_company.operation_natures.create!(description: 'Transferência Simples', kind: :transfer, cfop: '?152', final_consumer: false,
                                                 icms_situation: '400', pis_cst: '49', cofins_cst: '49')
    sign_in @admin
  end

  def save(companies, approver_ids: [''])
    patch internal_transfer_config_path, params: { approver_ids: approver_ids, companies: companies }
  end

  test 'the transfers list links to Configurações, which shows the fiscal note section per company' do
    get internal_transfers_path
    assert_select "a[href='#{edit_internal_transfer_config_path}']", text: /Configurações/

    get edit_internal_transfer_config_path
    assert_response :success
    assert_select 'h3', text: /Nota fiscal/
    assert_select "select[name='companies[#{@company.id}][location_id]']"
    assert_select "select[name='companies[#{@company.id}][internal_transfer_nature_id]'] option", text: /Transferência entre Filiais/
    assert_select "select[name='companies[#{@company.id}][internal_transfer_nature_id]'] option", text: /Transferência Simples/, count: 0
  end

  test 'saves the store and the nature of each company, links the nature and the notes use it' do
    save({ @company.id => { location_id: @bh.id, internal_transfer_nature_id: @shared.id },
           @other.id => { location_id: @lagoa.id, internal_transfer_nature_id: '' } }, approver_ids: ['', @admin.id])

    assert_redirected_to internal_transfers_path
    assert_equal @company, @bh.reload.company
    assert_equal @other, @lagoa.reload.company
    assert_equal @shared, @company.reload.internal_transfer_nature
    assert @company.available_natures.exists?(@shared.id)
    assert_equal @shared, @company.internal_transfer_nature_for_notes
    assert_equal OperationNature.default_for(@other, :transfer), @other.reload.internal_transfer_nature_for_notes
    assert_equal [@admin.id], InternalTransferApprover.user_ids
  end

  test 'moving a store to another company and clearing the nature' do
    @bh.update!(company: @other)
    @company.update_columns(internal_transfer_nature_id: @shared.id)

    save({ @company.id => { location_id: @bh.id, internal_transfer_nature_id: '' }, @other.id => { location_id: '', internal_transfer_nature_id: '' } })

    assert_equal @company, @bh.reload.company
    assert_nil @other.reload.location
    assert_nil @company.reload.internal_transfer_nature_id
    assert_equal @standard, @company.internal_transfer_nature_for_notes
  end

  test 'the same store in two companies or a nature of another regime is refused and nothing changes' do
    save({ @company.id => { location_id: @bh.id }, @other.id => { location_id: @bh.id } })
    assert_response :unprocessable_entity
    assert_match(/BH Shopping está em mais de uma/, flash[:alert])
    assert_nil @bh.reload.company

    save({ @company.id => { location_id: '', internal_transfer_nature_id: @simples.id } })
    assert_response :unprocessable_entity
    assert_match(/não serve para/, flash[:alert])
    assert_nil @company.reload.internal_transfer_nature_id
  end

  test 'a chosen nature that no longer fits falls back to the company default' do
    CompanyOperationNature.find_or_create_by!(company: @company, operation_nature: @shared)
    @company.update_columns(internal_transfer_nature_id: @shared.id)
    @shared.update!(active: false)

    assert_equal @standard, @company.reload.internal_transfer_nature_for_notes
  end
end
