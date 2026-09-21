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
end
