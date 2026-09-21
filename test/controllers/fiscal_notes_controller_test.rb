require 'test_helper'

class FiscalNotesControllerTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(name: 'Admin Notas', email: 'admin_notes@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @company = Company.create!(
      legal_name: 'Empresa Nota', cnpj: '11222333000181', tax_regime: 1, street: 'Rua A', number: '1',
      neighbourhood: 'Centro', city: 'BH', city_ibge_code: '3106200', state: 'MG', zip: '30000000'
    )
    @other = Company.create!(
      legal_name: 'Outra Empresa', cnpj: '45723174000110', tax_regime: 1, street: 'Rua B', number: '2',
      neighbourhood: 'Centro', city: 'BH', city_ibge_code: '3106200', state: 'MG', zip: '30000000'
    )
    @signed = FiscalNote.create!(company: @company, number: 1, series: 1, status: :assinada, environment: :homologacao,
                                 access_key: '3' * 44, total_value: 25.5)
    @failed = FiscalNote.create!(company: @other, number: 1, series: 1, status: :erro, environment: :homologacao,
                                 error_message: 'NCM ausente para o SKU X')
  end

  test 'user without fiscal_notes access is redirected' do
    profile = Profile.create!(name: 'Sem Acesso Notas')
    user = User.create!(name: 'Sem Acesso', email: 'sem_acesso_notes@example.com', password: 'password123')
    user.profiles << profile
    sign_in user

    get fiscal_notes_path
    assert_redirected_to root_path
    get xml_fiscal_note_path(@signed)
    assert_redirected_to root_path
  end

  test 'index lists notes and filters by status and company' do
    sign_in @admin

    get fiscal_notes_path
    assert_response :success
    assert_select 'tbody tr', count: 2

    get fiscal_notes_path(status: 'assinada')
    assert_select 'tbody tr', count: 1
    assert_select 'tbody', text: /Empresa Nota/

    get fiscal_notes_path(company_id: @other.id)
    assert_select 'tbody tr', count: 1
    assert_select 'tbody', text: /Outra Empresa/
  end

  test 'show displays the access key, company and error' do
    sign_in @admin

    get fiscal_note_path(@signed)
    assert_response :success
    assert_includes response.body, '3' * 44

    get fiscal_note_path(@failed)
    assert_select 'body', text: /NCM ausente para o SKU X/
  end

  test 'xml downloads the attached file as xml and never as a public url' do
    sign_in @admin
    @signed.xml.attach(io: StringIO.new('<NFe>conteudo</NFe>'), filename: 'nfe.xml', content_type: 'application/xml')

    get xml_fiscal_note_path(@signed)

    assert_response :success
    assert_equal 'application/xml', response.media_type
    assert_equal '<NFe>conteudo</NFe>', response.body
    assert_match(/attachment; filename="NFe#{'3' * 44}\.xml"/, response.headers['Content-Disposition'])
  end

  test 'xml without an attachment redirects with an alert' do
    sign_in @admin

    get xml_fiscal_note_path(@failed)

    assert_redirected_to fiscal_note_path(@failed)
    follow_redirect!
    assert_select '.flash-messages-container .alert', text: /XML/
  end
end
