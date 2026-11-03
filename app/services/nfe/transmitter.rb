require 'nokogiri'

module Nfe
  # Envia a nota assinada para autorização na SEFAZ (modo síncrono) e grava o resultado na FiscalNote.
  # Autorizada: o XML anexado vira o nfeProc (NFe + protocolo), que é o arquivo com validade fiscal.
  class Transmitter
    class Error < StandardError; end

    NS = { 'n' => 'http://www.portalfiscal.inf.br/nfe' }.freeze
    AUTHORIZED_CODES = %w[100 150].freeze
    # Uso denegado: a SEFAZ registra a nota e o número fica queimado (não dá para reaproveitar).
    DENIED_CODES = %w[110 205 301 302 303].freeze
    BATCH_PROCESSED = '104'.freeze
    BATCH_RECEIVED = '103'.freeze
    DUPLICATE = '204'.freeze
    RECEIPT_ATTEMPTS = 4
    RECEIPT_WAIT = 2

    def self.call(note, **opts)
      new(note, **opts).call
    end

    # consult: consulta pela chave em vez de enviar (para notas que ficaram sem resposta).
    def initialize(note, consult: false, client: nil, wait: RECEIPT_WAIT)
      @note = note
      @consult = consult
      @client = client || Sefaz::Client.new(note.company)
      @wait = wait
    end

    def call
      raise Error, 'A nota não tem XML assinado.' unless @note.xml_available?
      raise Error, 'A empresa da nota está em outro ambiente agora; volte o ambiente para transmitir.' if environment_mismatch?
      raise Error, 'Esta nota não pode ser transmitida.' unless @consult || @note.transmittable?

      @consult ? consult_by_key : authorize
      @note
    rescue Sefaz::Client::Error, Certificate::Error => e
      @note.update!(status: :erro, error_message: e.message)
      @note
    end

    private

    def environment_mismatch?
      @note.environment != @note.company.environment
    end

    def signed_nfe
      @signed_nfe ||= begin
        doc = Nokogiri::XML(@note.xml.download)
        # Uma nota já autorizada tem o nfeProc anexado; para reenviar só interessa a NFe.
        (doc.at_xpath('//n:NFe', NS) || doc.root).to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML)
      end
    end

    def authorize
      response = @client.authorize(signed_nfe, batch_id: batch_id)
      code, message = status_of(response, 'retEnviNFe')

      case code
      when BATCH_PROCESSED then apply_protocol(response.at_xpath('//n:protNFe', NS))
      when BATCH_RECEIVED then poll_receipt(response.at_xpath('//n:infRec/n:nRec', NS)&.text)
      else reject(code, message)
      end
    end

    def poll_receipt(receipt)
      @note.update!(sefaz_receipt: receipt, sefaz_status_code: BATCH_RECEIVED, sefaz_message: 'Lote recebido')
      RECEIPT_ATTEMPTS.times do
        sleep(@wait) if @wait.positive?
        response = @client.receipt(receipt)
        code, message = status_of(response, 'retConsReciNFe')
        return apply_protocol(response.at_xpath('//n:protNFe', NS)) if code == BATCH_PROCESSED
        return reject(code, message) unless code == '105' # 105: lote em processamento
      end
      @note.update!(status: :erro, error_message: "Lote #{receipt} ainda em processamento na SEFAZ. Consulte em instantes.")
    end

    def consult_by_key
      response = @client.consult(@note.access_key)
      code, message = status_of(response, 'retConsSitNFe')
      protocol = response.at_xpath('//n:protNFe', NS)
      return apply_protocol(protocol) if protocol && AUTHORIZED_CODES.include?(code)

      # 217: a SEFAZ não conhece a chave, então a nota nunca chegou lá e pode ser enviada de novo.
      if code == '217'
        @note.update!(status: :assinada, sefaz_status_code: code, sefaz_message: message, error_message: nil)
      else
        reject(code, message)
      end
    end

    def apply_protocol(protocol)
      code = protocol&.at_xpath('n:infProt/n:cStat', NS)&.text
      message = protocol&.at_xpath('n:infProt/n:xMotivo', NS)&.text
      return reject(code, message) unless AUTHORIZED_CODES.include?(code)

      authorized_at = Time.zone.parse(protocol.at_xpath('n:infProt/n:dhRecbto', NS).text.to_s) rescue Time.current
      proc_xml = build_nfe_proc(protocol)
      @note.update!(
        status: :autorizada, protocol: protocol.at_xpath('n:infProt/n:nProt', NS)&.text, authorized_at: authorized_at,
        sefaz_status_code: code, sefaz_message: message, error_message: nil
      )
      @note.xml.attach(io: StringIO.new(proc_xml), filename: "NFe#{@note.access_key}-procNFe.xml", content_type: 'application/xml')
    end

    def reject(code, message)
      if code == DUPLICATE && !@consult
        # Já autorizada antes (resposta anterior se perdeu): recupera o protocolo pela chave.
        @consult = true
        return consult_by_key
      end

      @note.update!(status: :rejeitada, sefaz_status_code: code, sefaz_message: message,
                    error_message: "Rejeição #{code}: #{message}")
    end

    def status_of(response, root)
      node = response.at_xpath("/n:#{root}", NS)
      raise Sefaz::Client::Error, "Resposta da SEFAZ sem #{root}." unless node

      [node.at_xpath('n:cStat', NS)&.text, node.at_xpath('n:xMotivo', NS)&.text]
    end

    def build_nfe_proc(protocol)
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?><nfeProc xmlns=\"#{NS['n']}\" versao=\"4.00\">" \
        "#{signed_nfe}#{protocol.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML)}</nfeProc>"
    end

    def batch_id
      format('%015d', (Time.current.to_f * 1000).to_i % 10**15)
    end
  end
end
