require 'test_helper'
require_relative '../support/nfe_test_certificate'

class CompaniesControllerTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(name: 'Admin Empresas', email: 'admin_companies@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
  end

  def company_params(overrides = {})
    { legal_name: 'Empresa Teste Ltda', cnpj: '11.222.333/0001-81', state_registration: '123456789',
      tax_regime: 1, street: 'Rua A', number: '10', neighbourhood: 'Centro', city: 'Belo Horizonte',
      city_ibge_code: '3106200', state: 'MG', zip: '30000-000' }.merge(overrides)
  end

  def certificate_upload(cnpj: '11222333000181')
    file = Tempfile.new(['cert', '.pfx'], binmode: true)
    file.write(NfeTestCertificate.pfx(cnpj: cnpj))
    file.rewind
    Rack::Test::UploadedFile.new(file.path, 'application/x-pkcs12')
  end

  test 'user without companies access is redirected' do
    profile = Profile.create!(name: 'Sem Acesso Empresas')
    user = User.create!(name: 'Sem Acesso', email: 'sem_acesso_companies@example.com', password: 'password123')
    user.profiles << profile
    sign_in user

    get companies_path
    assert_redirected_to root_path
  end

  test 'admin sees the companies list with the certificate status' do
    sign_in @admin
    Company.create!(company_params)

    get companies_path

    assert_response :success
    assert_select 'tbody tr', count: 1
    assert_select 'tbody', text: /Empresa Teste Ltda/
    assert_select 'tbody', text: /11\.222\.333\/0001-81/
    assert_select 'tbody', text: /Sem certificado/
  end

  test 'admin creates a company with a certificate, which is stored and shown as valid' do
    sign_in @admin

    assert_difference 'Company.count', 1 do
      post companies_path, params: { company: company_params(certificate_file: certificate_upload, certificate_password: 'senha123') }
    end
    assert_redirected_to companies_path

    company = Company.last
    assert company.certificate.attached?
    follow_redirect!
    assert_select 'tbody', text: /Válido/
  end

  test 'a certificate from another CNPJ is rejected and the form is re-rendered' do
    sign_in @admin

    assert_no_difference 'Company.count' do
      post companies_path, params: { company: company_params(certificate_file: certificate_upload(cnpj: '45723174000110'), certificate_password: 'senha123') }
    end

    assert_response :unprocessable_entity
    assert_select '.form-error-box', text: /outro CNPJ/
  end

  test 'editing without a new file or password keeps the current certificate' do
    sign_in @admin
    company = Company.create!(company_params(certificate_file: certificate_upload, certificate_password: 'senha123'))

    patch company_path(company), params: { company: { trade_name: 'Fantasia Nova', certificate_password: '' } }

    assert_redirected_to companies_path
    company.reload
    assert_equal 'Fantasia Nova', company.trade_name
    assert company.certificate.attached?
    assert_equal 'senha123', company.certificate_password
  end

  test 'the certificate password is never rendered' do
    sign_in @admin
    company = Company.create!(company_params(certificate_file: certificate_upload, certificate_password: 'senha123'))

    get edit_company_path(company)

    assert_response :success
    refute_includes response.body, 'senha123'
    assert_select 'input[type=password][value]', count: 0
  end

  test 'admin can destroy a company' do
    sign_in @admin
    company = Company.create!(company_params)

    assert_difference 'Company.count', -1 do
      delete company_path(company)
    end
    assert_redirected_to companies_path
  end

  test 'a company with fiscal notes cannot be destroyed' do
    sign_in @admin
    company = Company.create!(company_params)
    FiscalNote.create!(company: company, number: 1, series: 1, status: :assinada)

    assert_no_difference 'Company.count' do
      delete company_path(company)
    end
    assert_redirected_to companies_path
    follow_redirect!
    assert_select '.flash-messages-container .alert', text: /notas fiscais/
  end

  test 'company links natures created in another company; incompatible regime is refused' do
    sign_in @admin
    owner = Company.create!(company_params)
    other = Company.create!(company_params(legal_name: 'Outra Simples Ltda', cnpj: '45.723.174/0001-10'))
    normal = Company.create!(company_params(legal_name: 'Regime Normal Ltda', cnpj: '25.405.327/0001-74', tax_regime: 3))
    transfer = owner.operation_natures.create!(description: 'Transferência de mercadoria', kind: :transfer, cfop: '?152',
                                               icms_situation: '102', pis_cst: '49', cofins_cst: '49')
    assert_equal [transfer], owner.available_natures.to_a, 'a natureza fica vinculada à empresa em que foi criada'

    get edit_company_path(other)
    assert_select 'h5', text: /Naturezas de operação/
    assert_select 'h5', text: /CFOP e tributação padrão/, count: 0
    assert_select "input[name='company[nature_ids][]'][value='#{transfer.id}']"

    patch company_path(other), params: { company: { legal_name: other.legal_name, nature_ids: ['', transfer.id.to_s] } }
    assert_redirected_to companies_path
    assert_equal [transfer], other.reload.available_natures.to_a

    patch company_path(normal), params: { company: { legal_name: normal.legal_name, nature_ids: ['', transfer.id.to_s] } }
    assert_response :unprocessable_entity
    assert_empty normal.reload.available_natures

    patch company_path(other), params: { company: { legal_name: other.legal_name, nature_ids: [''] } }
    assert_empty other.reload.available_natures
  end

end
