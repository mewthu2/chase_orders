require 'openssl'

# Gera um certificado A1 (PKCS#12) autoassinado, no formato ICP-Brasil
# (CN "RAZAO SOCIAL:CNPJ"), só para testes.
module NfeTestCertificate
  module_function

  def pfx(cnpj: '11222333000181', password: 'senha123', not_after: Time.now + 365 * 86_400)
    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = OpenSSL::X509::Name.parse("/C=BR/O=ICP-Brasil/CN=EMPRESA TESTE LTDA:#{cnpj}")
    cert.issuer = cert.subject
    cert.public_key = key.public_key
    cert.not_before = Time.now - 86_400
    cert.not_after = not_after
    cert.sign(key, OpenSSL::Digest.new('SHA256'))
    OpenSSL::PKCS12.create(password, 'teste', key, cert).to_der
  end
end
