require 'nokogiri'

module Nfe
  # Cancela na SEFAZ uma NF-e autorizada (evento 110111), com a justificativa de quem pediu.
  # Evento homologado (135, 136 ou 155 fora do prazo): a nota fica "cancelada", com o protocolo do evento e o
  # procEventoNFe anexado em cancel_xml. Recusado: a nota continua autorizada e o motivo da SEFAZ vai no erro.
  class Canceller
    class Error < StandardError; end

    NS = { 'n' => 'http://www.portalfiscal.inf.br/nfe' }.freeze
    EVENT_TYPE = '110111'.freeze
    BATCH_PROCESSED = '128'.freeze
    # 135: registrado e vinculado; 136: registrado, não vinculado; 155: cancelamento homologado fora de prazo.
    ACCEPTED_CODES = %w[135 136 155].freeze
    REASON_RANGE = (15..255).freeze
    TIME_ZONE = 'America/Sao_Paulo'.freeze

    def self.call(note, reason:, user: nil, client: nil)
      new(note, reason:, user:, client:).call
    end

    def self.clean_reason(reason)
      reason.to_s.squish
    end

    def initialize(note, reason:, user: nil, client: nil)
      @note = note
      @reason = self.class.clean_reason(reason)
      @user = user
      @client = client || Sefaz::Client.new(note.company, environment: note.environment)
    end

    def call
      validate!
      signed = Signer.new(@note.company.nfe_certificate).sign(event_xml, tag: 'infEvento')
      response = @client.event(signed, batch_id: batch_id)
      apply(response, signed)
      @note
    rescue Sefaz::Client::Error, Certificate::Error, Signer::Error => e
      raise Error, "Não foi possível falar com a SEFAZ: #{e.message}"
    end

    private

    def validate!
      raise Error, 'Só nota autorizada pode ser cancelada na SEFAZ.' unless @note.autorizada?
      raise Error, 'A nota não tem chave de acesso ou protocolo de autorização.' if @note.access_key.blank? || @note.protocol.blank?
      return if REASON_RANGE.cover?(@reason.length)

      raise Error, "Escreva o motivo do cancelamento com #{REASON_RANGE.min} a #{REASON_RANGE.max} caracteres (tem #{@reason.length})."
    end

    def event_xml
      key = @note.access_key
      environment = @note.homologacao? ? '2' : '1'
      issued = Time.current.in_time_zone(TIME_ZONE).strftime('%Y-%m-%dT%H:%M:%S%:z')
      Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
        xml.evento(xmlns: NS['n'], versao: '1.00') do
          xml.infEvento(Id: "ID#{EVENT_TYPE}#{key}01") do
            xml.cOrgao key[0, 2]
            xml.tpAmb environment
            xml.CNPJ Cnpj.digits(@note.company.cnpj)
            xml.chNFe key
            xml.dhEvento issued
            xml.tpEvento EVENT_TYPE
            xml.nSeqEvento '1'
            xml.verEvento '1.00'
            xml.detEvento(versao: '1.00') do
              xml.descEvento 'Cancelamento'
              xml.nProt @note.protocol
              xml.xJust @reason
            end
          end
        end
      end.doc.root.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML)
    end

    def apply(response, signed)
      batch_code = response.at_xpath('/n:retEnvEvento/n:cStat', NS)&.text
      batch_message = response.at_xpath('/n:retEnvEvento/n:xMotivo', NS)&.text
      info = response.at_xpath('//n:retEvento/n:infEvento', NS)
      unless batch_code == BATCH_PROCESSED && info
        raise Error, "A SEFAZ não processou o cancelamento: #{batch_code} #{batch_message}".strip
      end

      code = info.at_xpath('n:cStat', NS)&.text
      message = info.at_xpath('n:xMotivo', NS)&.text
      raise Error, "A SEFAZ recusou o cancelamento: #{code} #{message}".strip unless ACCEPTED_CODES.include?(code)

      ret_event = response.at_xpath('//n:retEvento', NS).to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML)
      registered_at = Time.zone.parse(info.at_xpath('n:dhRegEvento', NS)&.text.to_s) || Time.current
      @note.update!(status: :cancelada, cancel_reason: @reason, cancel_protocol: info.at_xpath('n:nProt', NS)&.text,
                    canceled_at: registered_at, canceled_by: @user&.name, sefaz_status_code: code, sefaz_message: message,
                    error_message: nil)
      @note.cancel_xml.attach(io: StringIO.new(proc_event(signed, ret_event)), filename: "NFe#{@note.access_key}-procEventoNFe-cancelamento.xml",
                              content_type: 'application/xml')
    end

    def proc_event(signed, ret_event)
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?><procEventoNFe xmlns=\"#{NS['n']}\" versao=\"1.00\">" \
        "#{signed.sub(/\A\s*<\?xml[^>]*\?>\s*/, '')}#{ret_event}</procEventoNFe>"
    end

    def batch_id
      format('%015d', (Time.current.to_f * 1000).to_i % 10**15)
    end
  end
end
