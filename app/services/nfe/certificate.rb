require 'openssl'
require 'base64'

module Nfe
  # Certificado digital A1 (PKCS#12/.pfx) de uma empresa emissora.
  class Certificate
    class Error < StandardError; end

    attr_reader :certificate, :private_key

    def initialize(pfx_data, password)
      pkcs12 = OpenSSL::PKCS12.new(pfx_data.to_s, password.to_s)
      @certificate = pkcs12.certificate
      @private_key = pkcs12.key
      raise Error, 'Certificado sem chave privada ou sem certificado.' unless @certificate && @private_key
    rescue OpenSSL::PKCS12::PKCS12Error, ArgumentError, TypeError
      raise Error, 'Senha do certificado inválida ou arquivo corrompido.'
    end

    def expires_at
      certificate.not_after
    end

    def expired?
      expires_at < Time.now
    end

    def subject
      certificate.subject.to_s
    end

    # Certificados ICP-Brasil trazem o CNPJ no CN ("RAZAO SOCIAL:12345678000199").
    def cnpj
      common_name = certificate.subject.to_a.find { |name, _, _| name == 'CN' }&.[](1).to_s
      common_name[/\d{14}/]
    end

    def base64_der
      Base64.strict_encode64(certificate.to_der)
    end
  end
end
