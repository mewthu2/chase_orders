require 'net/http'
require 'nokogiri'

module Nfe
  module Sefaz
    # Chamadas SOAP 1.2 aos web services da SEFAZ, autenticadas com o certificado A1 da empresa (TLS mútuo).
    # Devolve o XML de retorno (retEnviNFe, retConsReciNFe ou retConsSitNFe) sem o envelope SOAP.
    class Client
      class Error < StandardError; end

      NFE_NS = 'http://www.portalfiscal.inf.br/nfe'.freeze
      WSDL_NS = 'http://www.portalfiscal.inf.br/nfe/wsdl/'.freeze
      OPERATIONS = {
        autorizacao: %w[NFeAutorizacao4 nfeAutorizacaoLote],
        ret_autorizacao: %w[NFeRetAutorizacao4 nfeRetAutorizacaoLote],
        consulta_protocolo: %w[NFeConsultaProtocolo4 nfeConsultaNF]
      }.freeze
      # Os servidores da SEFAZ usam certificados da ICP-Brasil, que não vêm no repositório padrão de CAs.
      ICP_BRASIL_ROOTS = Rails.root.join('config/certs/icp_brasil_roots.pem').to_s.freeze

      # environment: o da nota (pode ser diferente do que a empresa está usando agora).
      def initialize(company, environment: company.environment)
        @company = company
        @environment = environment.to_s
      end

      # signed_nfe: o XML da NFe assinada, sem declaração <?xml?>.
      def authorize(signed_nfe, batch_id:)
        body = "<enviNFe xmlns=\"#{NFE_NS}\" versao=\"4.00\"><idLote>#{batch_id}</idLote>" \
               "<indSinc>1</indSinc>#{strip_declaration(signed_nfe)}</enviNFe>"
        call(:autorizacao, body)
      end

      def receipt(number)
        call(:ret_autorizacao, "<consReciNFe xmlns=\"#{NFE_NS}\" versao=\"4.00\"><tpAmb>#{tp_amb}</tpAmb>" \
                               "<nRec>#{number}</nRec></consReciNFe>")
      end

      def consult(access_key)
        call(:consulta_protocolo, "<consSitNFe xmlns=\"#{NFE_NS}\" versao=\"4.00\"><tpAmb>#{tp_amb}</tpAmb>" \
                                  "<xServ>CONSULTAR</xServ><chNFe>#{access_key}</chNFe></consSitNFe>")
      end

      private

      def tp_amb
        @environment == 'homologacao' ? '2' : '1'
      end

      def strip_declaration(xml)
        xml.to_s.sub(/\A\s*<\?xml[^>]*\?>\s*/, '')
      end

      def call(service, payload)
        wsdl, action = OPERATIONS.fetch(service)
        uri = URI(Webservices.url(@company.state, @environment, service))
        envelope = '<?xml version="1.0" encoding="utf-8"?>' \
                   '<soap12:Envelope xmlns:soap12="http://www.w3.org/2003/05/soap-envelope">' \
                   "<soap12:Body><nfeDadosMsg xmlns=\"#{WSDL_NS}#{wsdl}\">#{payload}</nfeDadosMsg></soap12:Body>" \
                   '</soap12:Envelope>'

        request = Net::HTTP::Post.new(uri)
        request['Content-Type'] = "application/soap+xml; charset=utf-8; action=\"#{WSDL_NS}#{wsdl}/#{action}\""
        request.body = envelope

        response = http(uri).request(request)
        unless response.is_a?(Net::HTTPSuccess)
          raise Error, "SEFAZ respondeu HTTP #{response.code}: #{soap_fault(response.body) || response.message}"
        end

        extract_result(response.body)
      rescue Webservices::Unsupported => e
        raise Error, e.message
      rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET,
             OpenSSL::SSL::SSLError, EOFError => e
        raise Error, "Falha de comunicação com a SEFAZ: #{e.message}"
      end

      def http(uri)
        certificate = @company.nfe_certificate
        Net::HTTP.new(uri.host, uri.port).tap do |http|
          http.use_ssl = true
          http.cert = certificate.certificate
          http.key = certificate.private_key
          http.cert_store = cert_store
          http.verify_mode = OpenSSL::SSL::VERIFY_PEER
          http.open_timeout = 15
          http.read_timeout = 60
        end
      end

      def cert_store
        OpenSSL::X509::Store.new.tap do |store|
          store.set_default_paths
          store.add_file(ICP_BRASIL_ROOTS)
        end
      end

      def extract_result(body)
        doc = Nokogiri::XML(body)
        result = doc.at_xpath('//*[local-name()="nfeResultMsg"]/*')
        raise Error, "Resposta inesperada da SEFAZ: #{soap_fault(body) || body.to_s.first(200)}" unless result

        Nokogiri::XML(result.to_xml)
      end

      def soap_fault(body)
        Nokogiri::XML(body.to_s).at_xpath('//*[local-name()="Text" or local-name()="faultstring"]')&.text&.strip.presence
      end
    end
  end
end
