require 'test_helper'
require 'minitest/mock'

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

  test 'an authorized note shows Cancelar na SEFAZ with the reason form; canceling records it and shows the event' do
    @signed.update!(status: :autorizada, protocol: '131260000000001', authorized_at: 2.hours.ago)
    sign_in @admin

    get fiscal_note_path(@signed)
    assert_select 'a.nf-cancel-open', text: /Cancelar na SEFAZ/
    assert_select "form[action='#{cancel_fiscal_note_path(@signed)}'] textarea[name='reason'][minlength='15'][maxlength='255']"

    received = nil
    fake = lambda do |note, reason:, user:|
      received = [reason, user]
      note.update!(status: :cancelada, cancel_reason: reason, cancel_protocol: '131260000000999', canceled_at: Time.current, canceled_by: user.name)
      note
    end
    Nfe::Canceller.stub(:call, fake) do
      post cancel_fiscal_note_path(@signed), params: { reason: 'Nota emitida com o destinatario errado' }
    end

    assert_redirected_to fiscal_note_path(@signed)
    assert_equal ['Nota emitida com o destinatario errado', @admin], received
    follow_redirect!
    assert_select '.nf-canceled', text: /Cancelada na SEFAZ \(homologação\): Nota emitida com o destinatario errado/
    assert_select 'a.nf-cancel-open', count: 0
    assert Log.where(resource_type: 'fiscal_note', action_type: 'cancel', resource_id: @signed.id).exists?
  end

  test 'a refused cancellation comes back to the form with the SEFAZ message' do
    @signed.update!(status: :autorizada, protocol: '131260000000001', authorized_at: 2.days.ago)
    sign_in @admin

    Nfe::Canceller.stub(:call, ->(*, **) { raise Nfe::Canceller::Error, 'A SEFAZ recusou o cancelamento: 501 Prazo' }) do
      post cancel_fiscal_note_path(@signed), params: { reason: 'Motivo com tamanho suficiente' }
    end

    assert_redirected_to fiscal_note_path(@signed, cancelar: 1)
    follow_redirect!
    assert_match(/501 Prazo/, response.body)
    assert_select '#cancelar[data-open]'
    assert_match(/Já passou o prazo normal de 24 horas/, response.body)
  end

  test 'the list offers Cancelar na SEFAZ only for authorized notes' do
    @signed.update!(status: :autorizada, protocol: '131260000000001', authorized_at: 1.hour.ago)
    sign_in @admin

    get fiscal_notes_path

    assert_select "a[data-tip='Cancelar na SEFAZ'][href='#{fiscal_note_path(@signed, cancelar: 1, anchor: 'cancelar')}']", count: 1
  end

  test 'a note that is not authorized has no cancel option' do
    sign_in @admin

    get fiscal_note_path(@signed)

    assert_select 'a.nf-cancel-open', count: 0
    assert_select '#cancelar', count: 0
  end
end
