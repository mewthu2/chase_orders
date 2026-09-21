require 'test_helper'
require_relative '../support/nfe_test_certificate'

class CompanyTest < ActiveSupport::TestCase
  def valid_attributes(overrides = {})
    { legal_name: 'Empresa Teste Ltda', cnpj: '11.222.333/0001-81', state_registration: '123456789',
      tax_regime: 1, street: 'Rua A', number: '10', neighbourhood: 'Centro', city: 'Belo Horizonte',
      city_ibge_code: '3106200', state: 'MG', zip: '30000-000' }.merge(overrides)
  end

  def upload(pfx)
    file = Tempfile.new(['cert', '.pfx'], binmode: true)
    file.write(pfx)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, 'application/x-pkcs12')
  end

  test 'is valid with the required fiscal data and normalizes the CNPJ to digits' do
    company = Company.new(valid_attributes)
    assert company.valid?, company.errors.full_messages.to_sentence
    assert_equal '11222333000181', company.cnpj
    assert_equal '11.222.333/0001-81', company.cnpj_formatted
  end

  test 'requires a valid and unique CNPJ' do
    refute Company.new(valid_attributes(cnpj: '11222333000182')).valid?
    Company.create!(valid_attributes)
    refute Company.new(valid_attributes).valid?
  end

  test 'requires a valid state and tax regime, and exposes the IBGE state code' do
    refute Company.new(valid_attributes(state: 'XX')).valid?
    refute Company.new(valid_attributes(tax_regime: 9)).valid?
    assert_equal '31', Company.new(valid_attributes).state_code
  end

  test 'has the default CFOPs, series, numbering and homologation environment' do
    company = Company.new
    assert_equal %w[5102 6102 5152 6152],
                 [company.cfop_sale_in_state, company.cfop_sale_out_of_state,
                  company.cfop_transfer_in_state, company.cfop_transfer_out_of_state]
    assert_equal 1, company.nfe_series
    assert_equal 1, company.next_nfe_number
    assert company.homologacao?
  end

  test 'accepts a certificate whose CNPJ matches and stores its metadata' do
    company = Company.new(valid_attributes(certificate_file: upload(NfeTestCertificate.pfx), certificate_password: 'senha123'))
    assert company.save, company.errors.full_messages.to_sentence
    assert company.certificate.attached?
    assert_equal '11222333000181', company.certificate_cnpj
    assert company.certificate_expires_at > Time.current
    assert_equal :valid, company.certificate_status
    assert company.ready_to_issue?
    assert_equal '11222333000181', company.nfe_certificate.cnpj
  end

  test 'rejects a certificate with the wrong password, another CNPJ or expired' do
    wrong_password = Company.new(valid_attributes(certificate_file: upload(NfeTestCertificate.pfx), certificate_password: 'errada'))
    refute wrong_password.valid?
    assert_match(/senha/i, wrong_password.errors[:certificate_file].to_sentence)

    other_cnpj = Company.new(valid_attributes(certificate_file: upload(NfeTestCertificate.pfx(cnpj: '45723174000110')), certificate_password: 'senha123'))
    refute other_cnpj.valid?
    assert_match(/outro CNPJ/, other_cnpj.errors[:certificate_file].to_sentence)

    expired = Company.new(valid_attributes(certificate_file: upload(NfeTestCertificate.pfx(not_after: Time.now - 60)), certificate_password: 'senha123'))
    refute expired.valid?
    assert_match(/vencido/, expired.errors[:certificate_file].to_sentence)
  end

  test 'requires the password when a certificate is uploaded' do
    refute Company.new(valid_attributes(certificate_file: upload(NfeTestCertificate.pfx))).valid?
  end

  test 'certificate password is stored encrypted' do
    company = Company.create!(valid_attributes(certificate_file: upload(NfeTestCertificate.pfx), certificate_password: 'senha123'))
    raw = Company.connection.select_value("SELECT certificate_password FROM companies WHERE id = #{company.id}")
    assert_not_equal 'senha123', raw
    assert_equal 'senha123', company.reload.certificate_password
  end

  test 'certificate_status reflects missing, expired and expiring certificates' do
    assert_equal :missing, Company.new(valid_attributes).certificate_status

    company = Company.create!(valid_attributes(certificate_file: upload(NfeTestCertificate.pfx), certificate_password: 'senha123'))
    company.update_column(:certificate_expires_at, 10.days.from_now)
    assert_equal :expiring, company.certificate_status
    assert company.ready_to_issue?

    company.update_column(:certificate_expires_at, 1.day.ago)
    assert_equal :expired, company.certificate_status
    refute company.ready_to_issue?
  end

  test 'ready_to_issue scope only includes active companies with an unexpired certificate' do
    ready = Company.create!(valid_attributes(certificate_file: upload(NfeTestCertificate.pfx), certificate_password: 'senha123'))
    Company.create!(valid_attributes(cnpj: '45723174000110', legal_name: 'Sem Certificado'))
    inactive = Company.create!(valid_attributes(cnpj: '07526557000100', legal_name: 'Inativa', active: false))
    inactive.update_columns(certificate_expires_at: 1.year.from_now)

    assert_equal [ready], Company.ready_to_issue.to_a
  end
end
