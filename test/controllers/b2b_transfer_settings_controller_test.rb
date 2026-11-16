require 'test_helper'
require_relative '../support/nfe_company_factory'

# Abastecimento Lojas → Configurações e Transferência B2B → B2C → Configurações: empresa e natureza da NF-e de cada tipo.
class B2bTransferSettingsControllerTest < ActionDispatch::IntegrationTest
  include NfeCompanyFactory

  def setup
    @admin = User.create!(name: 'Admin', email: 'admin_bts@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @wholesale = create_nfe_company(tax_regime: 3)
    @contagem = create_nfe_company(legal_name: 'Chase Contagem Ltda', cnpj: '45.723.174/0001-10', state_registration: '87654321', tax_regime: 3)
    @old = transfer_nature(@wholesale, 'Transferência entre Filiais - MG')
    @supply = transfer_nature(@contagem, 'Transferência para lojas')
    @b2c = transfer_nature(@contagem, 'Transferência para a filial B2C')
    @setting = B2bSetting.current
    @setting.update!(issuer_company: @wholesale, transfer_nature: @old)
    sign_in @admin
  end

  def transfer_nature(company, description)
    company.operation_natures.create!(description:, kind: :transfer, cfop: '?152', final_consumer: false,
                                      icms_situation: '00', icms_rate: 18, pis_cst: '01', cofins_cst: '01')
  end

  test 'both lists link to their own Configurações' do
    get stock_transfers_path
    assert_select "a[href='#{stock_transfer_settings_path}']", text: /Configurações/
    get b2c_transfers_path
    assert_select "a[href='#{b2c_transfer_settings_path}']", text: /Configurações/
  end

  test 'without a choice the transfers keep the wholesale company and the old transfer nature' do
    get stock_transfer_settings_path

    assert_response :success
    assert_select "select[name='b2b_setting[supply_issuer_company_id]'] option[selected][value='#{@wholesale.id}']"
    assert_select "select[name='b2b_setting[supply_nature_id]'] option[selected][value='#{@old.id}']"
    assert_equal @wholesale, @setting.issuer(B2bOrder.new(kind: :b2c_transfer))
    assert_equal @old, @setting.nature_for(B2bOrder.new(kind: :b2c_transfer))
  end

  test 'each screen saves its own company and nature, links the nature, and the sale stays as it was' do
    patch stock_transfer_settings_path, params: { b2b_setting: { supply_issuer_company_id: @contagem.id, supply_nature_id: @supply.id,
                                                                  b2c_nature_id: @old.id } }
    assert_redirected_to stock_transfers_path
    patch b2c_transfer_settings_path, params: { b2b_setting: { b2c_issuer_company_id: @contagem.id, b2c_nature_id: @b2c.id } }
    assert_redirected_to b2c_transfers_path

    @setting.reload
    assert_equal [@contagem, @supply], [@setting.issuer(B2bOrder.new(kind: :stock_transfer)), @setting.nature_for(B2bOrder.new(kind: :stock_transfer))]
    assert_equal [@contagem, @b2c], [@setting.issuer(B2bOrder.new(kind: :b2c_transfer)), @setting.nature_for(B2bOrder.new(kind: :b2c_transfer))]
    assert_equal @wholesale, @setting.issuer(B2bOrder.new(kind: :sale))
    assert @contagem.available_natures.exists?(@supply.id)
    assert @contagem.available_natures.exists?(@b2c.id)
  end

  test 'a sale nature is refused as a transfer nature' do
    sale = @contagem.operation_natures.create!(description: 'Venda', kind: :sale, cfop: '?102', final_consumer: false,
                                               icms_situation: '00', icms_rate: 18, pis_cst: '01', cofins_cst: '01')

    patch b2c_transfer_settings_path, params: { b2b_setting: { b2c_nature_id: sale.id } }

    assert_response :unprocessable_entity
    assert_nil @setting.reload.b2c_nature_id
  end

  test 'the store supply screen permission is required' do
    user = User.create!(name: 'Sem acesso', email: 'sem_bts@example.com', password: 'password123')
    sign_in user

    get b2c_transfer_settings_path

    assert_not_equal 200, response.status
  end
end
