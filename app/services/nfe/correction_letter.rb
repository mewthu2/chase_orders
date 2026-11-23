require 'nokogiri'

module Nfe
  # Carta de Correção Eletrônica (CC-e, evento 110110) no leiaute da Receita (e110110 v1.00), para uma NF-e
  # autorizada. Cada carta nova recebe o próximo nSeqEvento (1 a 20) e substitui as anteriores: a correção tem de
  # trazer tudo o que precisa ser corrigido. Registrada (135/136): grava a carta com o protocolo e o
  # procEventoNFe. Recusada: nada muda e o motivo da SEFAZ vai no erro.
  class CorrectionLetter
    class Error < StandardError; end

    NS = { 'n' => 'http://www.portalfiscal.inf.br/nfe' }.freeze
    EVENT_TYPE = '110110'.freeze
    DESCRIPTION = 'Carta de Correcao'.freeze
    BATCH_PROCESSED = '128'.freeze
    # 135: registrado e vinculado à NF-e; 136: registrado, mas não vinculado.
    ACCEPTED_CODES = %w[135 136].freeze
    TEXT_RANGE = (15..1000).freeze
    MAX_SEQUENCE = 20
    TIME_ZONE = 'America/Sao_Paulo'.freeze
    # Texto fixo do leiaute (enumeração do XSD): vai no XML exatamente assim, sem acentos.
    CONDITIONS_OF_USE = 'A Carta de Correcao e disciplinada pelo paragrafo 1o-A do art. 7o do Convenio S/N, de 15 de dezembro ' \
                        'de 1970 e pode ser utilizada para regularizacao de erro ocorrido na emissao de documento fiscal, desde ' \
                        'que o erro nao esteja relacionado com: I - as variaveis que determinam o valor do imposto tais como: ' \
                        'base de calculo, aliquota, diferenca de preco, quantidade, valor da operacao ou da prestacao; II - a ' \
                        'correcao de dados cadastrais que implique mudanca do remetente ou do destinatario; III - a data de ' \
                        'emissao ou de saida.'.freeze
    # O XSD só aceita caracteres até U+00FF e sem quebra de linha.
    REPLACEMENTS = { /[‐-―]/ => '-', /[‘’‚′]/ => "'", /[“”„″]/ => '"',
                     /…/ => '...', /•/ => '-' }.freeze

    def self.call(note, text:, user: nil, client: nil)
      new(note, text:, user:, client:).call
    end

    def self.clean_text(text)
      clean = text.to_s.squish
      REPLACEMENTS.each { |pattern, replacement| clean = clean.gsub(pattern, replacement) }
      clean.gsub(/[^ -ÿ]/) { |char| I18n.transliterate(char) }.squish
    end

    def initialize(note, text:, user: nil, client: nil)
      @note = note
      @text = self.class.clean_text(text)
      @user = user
      @client = client || Sefaz::Client.new(note.company, environment: note.environment)
    end

    def call
      validate!
      @sequence = @note.corrections.maximum(:sequence).to_i + 1
      signed = Signer.new(@note.company.nfe_certificate).sign(event_xml, tag: 'infEvento')
      response = @client.event(signed, batch_id: batch_id)
      apply(response, signed)
    rescue Sefaz::Client::Error, Certificate::Error, Signer::Error => e
      raise Error, "Não foi possível falar com a SEFAZ: #{e.message}"
    end

    private

    def validate!
      raise Error, 'Só nota autorizada pode receber carta de correção.' unless @note.autorizada?
      raise Error, 'A nota não tem chave de acesso ou protocolo de autorização.' if @note.access_key.blank? || @note.protocol.blank?
      if @note.corrections.count >= MAX_SEQUENCE
        raise Error, "A nota já tem #{MAX_SEQUENCE} cartas de correção, o máximo que a SEFAZ aceita."
      end
      return if TEXT_RANGE.cover?(@text.length)

      raise Error, "Escreva a correção com #{TEXT_RANGE.min} a #{TEXT_RANGE.max} caracteres (tem #{@text.length})."
    end

    def event_xml
      key = @note.access_key
      environment = @note.homologacao? ? '2' : '1'
      issued = Time.current.in_time_zone(TIME_ZONE).strftime('%Y-%m-%dT%H:%M:%S%:z')
      Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
        xml.evento(xmlns: NS['n'], versao: '1.00') do
          xml.infEvento(Id: "ID#{EVENT_TYPE}#{key}#{format('%02d', @sequence)}") do
            xml.cOrgao key[0, 2]
            xml.tpAmb environment
            xml.CNPJ Cnpj.digits(@note.company.cnpj)
            xml.chNFe key
            xml.dhEvento issued
            xml.tpEvento EVENT_TYPE
            xml.nSeqEvento @sequence.to_s
            xml.verEvento '1.00'
            xml.detEvento(versao: '1.00') do
              xml.descEvento DESCRIPTION
              xml.xCorrecao @text
              xml.xCondUso CONDITIONS_OF_USE
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
        raise Error, "A SEFAZ não processou a carta de correção: #{batch_code} #{batch_message}".strip
      end

      code = info.at_xpath('n:cStat', NS)&.text
      message = info.at_xpath('n:xMotivo', NS)&.text
      raise Error, "A SEFAZ recusou a carta de correção: #{code} #{message}".strip unless ACCEPTED_CODES.include?(code)

      ret_event = response.at_xpath('//n:retEvento', NS).to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML)
      registered_at = Time.zone.parse(info.at_xpath('n:dhRegEvento', NS)&.text.to_s) || Time.current
      correction = @note.corrections.create!(sequence: @sequence, correction: @text, protocol: info.at_xpath('n:nProt', NS)&.text,
                                             registered_at: registered_at, created_by: @user&.name,
                                             sefaz_status_code: code, sefaz_message: message)
      correction.xml.attach(io: StringIO.new(proc_event(signed, ret_event)), content_type: 'application/xml',
                            filename: "NFe#{@note.access_key}-procEventoNFe-cce-#{format('%02d', @sequence)}.xml")
      correction
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
