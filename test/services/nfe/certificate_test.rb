require 'test_helper'
require_relative '../../support/nfe_test_certificate'

class Nfe::CertificateTest < ActiveSupport::TestCase
  test 'reads validity, subject and CNPJ from a valid PKCS#12' do
    cert = Nfe::Certificate.new(NfeTestCertificate.pfx, 'senha123')

    assert_equal '11222333000181', cert.cnpj
    assert_match(/EMPRESA TESTE LTDA/, cert.subject)
    assert cert.expires_at > Time.now
    refute cert.expired?
    assert_kind_of OpenSSL::PKey::RSA, cert.private_key
    assert cert.base64_der.present?
  end

  test 'flags an expired certificate' do
    cert = Nfe::Certificate.new(NfeTestCertificate.pfx(not_after: Time.now - 60), 'senha123')
    assert cert.expired?
  end

  test 'raises a readable error with the wrong password' do
    error = assert_raises(Nfe::Certificate::Error) { Nfe::Certificate.new(NfeTestCertificate.pfx, 'errada') }
    assert_match(/senha/i, error.message)
  end

  test 'raises a readable error for a corrupted file' do
    assert_raises(Nfe::Certificate::Error) { Nfe::Certificate.new('lixo', 'senha123') }
  end
end
