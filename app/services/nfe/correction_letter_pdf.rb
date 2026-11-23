require 'prawn'

Prawn::Fonts::AFM.hide_m17n_warning = true

module Nfe
  # DACCE: impressão da Carta de Correção Eletrônica (A4), montada a partir do procEventoNFe da carta e do XML da
  # nota (emitente e destinatário). Não consulta banco nem SEFAZ.
  class CorrectionLetterPdf
    NS = { 'n' => 'http://www.portalfiscal.inf.br/nfe' }.freeze
    WIDTH = 555.28
    LABEL_SIZE = 6
    VALUE_SIZE = 9
    ROW = 24
    WATERMARK = 'B0B0B0'.freeze

    def initialize(event_xml, note_xml)
      @event = Nokogiri::XML(event_xml)
      @note = Nokogiri::XML(note_xml.to_s)
    end

    def filename
      "CCe-#{access_key}-#{format('%02d', sequence)}.pdf"
    end

    def render
      @pdf = Prawn::Document.new(page_size: 'A4', margin: [24, 20, 24, 20],
                                 info: { Title: "Carta de Correção #{access_key}", Creator: 'Honey Chase' })
      @pdf.font 'Helvetica'
      title
      event_rows
      parties
      text_block('CORREÇÃO', at('//n:evento/n:infEvento/n:detEvento/n:xCorrecao'), size: 10, min_height: 160)
      text_block('CONDIÇÕES DE USO', at('//n:evento/n:infEvento/n:detEvento/n:xCondUso'), size: 7.5, min_height: 60)
      footer
      watermark if homologation?
      @pdf.render
    end

    private

    def at(path, doc = @event)
      doc.at_xpath(path, NS)&.text.to_s.strip
    end

    def access_key
      at('//n:evento/n:infEvento/n:chNFe')
    end

    def sequence
      at('//n:evento/n:infEvento/n:nSeqEvento').to_i
    end

    def homologation?
      at('//n:evento/n:infEvento/n:tpAmb') == '2'
    end

    def title
      top = @pdf.cursor
      @pdf.stroke_rectangle([0, top], WIDTH, 52)
      @pdf.text_box 'CARTA DE CORREÇÃO ELETRÔNICA', at: [0, top - 8], width: WIDTH, size: 14, style: :bold, align: :center
      @pdf.text_box txt('Documento auxiliar da Carta de Correção Eletrônica (DACCE). Não substitui a NF-e: vale junto com ela.'),
                    at: [0, top - 28], width: WIDTH, size: 8, align: :center
      @pdf.move_down 56
    end

    def event_rows
      section('EVENTO')
      ret = '//n:retEvento/n:infEvento'
      row([['CHAVE DE ACESSO DA NF-e', access_key.scan(/\d{1,4}/).join(' '), 3, { style: :bold }],
           ['NÚMERO / SÉRIE', number_label, 1]])
      row([['ÓRGÃO', at('//n:evento/n:infEvento/n:cOrgao'), 1],
           ['AMBIENTE', homologation? ? '2 - Homologação' : '1 - Produção', 1.4],
           ['TIPO DO EVENTO', "#{at('//n:evento/n:infEvento/n:tpEvento')} - Carta de Correção", 2],
           ['SEQUÊNCIA', sequence.to_s, 0.8],
           ['DATA DO EVENTO', datetime(at('//n:evento/n:infEvento/n:dhEvento')), 1.4]])
      row([['STATUS', "#{at("#{ret}/n:cStat")} - #{at("#{ret}/n:xMotivo")}", 3],
           ['PROTOCOLO', at("#{ret}/n:nProt"), 1.4, { style: :bold }],
           ['DATA DO REGISTRO', datetime(at("#{ret}/n:dhRegEvento")), 1.4]])
    end

    def parties
      section('EMITENTE')
      row([['NOME / RAZÃO SOCIAL', at('//n:emit/n:xNome', @note), 3],
           ['CNPJ', document(at('//n:emit/n:CNPJ', @note).presence || at('//n:evento/n:infEvento/n:CNPJ')), 1.4],
           ['INSCRIÇÃO ESTADUAL', at('//n:emit/n:IE', @note), 1.2]])
      row([['ENDEREÇO', address('emit', 'enderEmit'), 1]])
      return if @note.at_xpath('//n:dest', NS).nil?

      section('DESTINATÁRIO')
      row([['NOME / RAZÃO SOCIAL', at('//n:dest/n:xNome', @note), 3],
           ['CNPJ / CPF', document(at('//n:dest/n:CNPJ', @note).presence || at('//n:dest/n:CPF', @note)), 1.4],
           ['DATA DE EMISSÃO DA NF-e', date(at('//n:ide/n:dhEmi', @note)), 1.2]])
      row([['ENDEREÇO', address('dest', 'enderDest'), 1]])
    end

    def text_block(label, value, size:, min_height:)
      section(label)
      text = txt(value)
      height = [@pdf.height_of(text, width: WIDTH - 12, size: size) + 14, min_height].max
      @pdf.start_new_page if height > @pdf.cursor
      top = @pdf.cursor
      @pdf.stroke_rectangle([0, top], WIDTH, height)
      @pdf.text_box text, at: [6, top - 7], width: WIDTH - 12, height: height - 10, size: size, leading: 2
      @pdf.move_down height
    end

    def footer
      @pdf.move_down 8
      @pdf.text txt('Consulte a autenticidade em www.nfe.fazenda.gov.br/portal pela chave de acesso da NF-e. ' \
                    'Vale a última carta de correção registrada: cada carta substitui as anteriores.'),
                size: 7, align: :center
    end

    def watermark
      @pdf.repeat(:all) do
        @pdf.fill_color WATERMARK
        @pdf.text_box 'SEM VALOR FISCAL - HOMOLOGAÇÃO', at: [0, 420], width: WIDTH, size: 26, style: :bold, align: :center,
                                                         rotate: 30, rotate_around: :center
        @pdf.fill_color '000000'
      end
    end

    def section(title)
      @pdf.move_down 6
      @pdf.text txt(title), size: 7.5, style: :bold
      @pdf.move_down 2
    end

    def row(columns, height: ROW)
      total_weight = columns.sum { |c| c[2] }
      top = @pdf.cursor
      x = 0
      columns.each_with_index do |(label, value, weight, opts), index|
        width = index == columns.size - 1 ? WIDTH - x : (WIDTH * weight / total_weight).round(2)
        @pdf.stroke_rectangle([x, top], width, height)
        @pdf.text_box txt(label), at: [x + 3, top - 2], width: width - 6, height: 8, size: LABEL_SIZE
        @pdf.text_box txt(value), at: [x + 3, top - 11], width: width - 6, height: height - 12, size: VALUE_SIZE,
                                  style: (opts || {})[:style] || :normal, overflow: :shrink_to_fit, min_font_size: 5
        x += width
      end
      @pdf.move_down height
    end

    def number_label
      number = at('//n:ide/n:nNF', @note)
      return access_key[25, 9].to_i.to_s if number.blank? && access_key.length == 44

      "#{number} / #{at('//n:ide/n:serie', @note)}"
    end

    def address(party, tag)
      base = "//n:#{party}/n:#{tag}"
      [[at("#{base}/n:xLgr", @note), at("#{base}/n:nro", @note), at("#{base}/n:xCpl", @note)].reject(&:blank?).join(', '),
       at("#{base}/n:xBairro", @note), "#{at("#{base}/n:xMun", @note)}/#{at("#{base}/n:UF", @note)}",
       ("CEP #{zip(at("#{base}/n:CEP", @note))}" if at("#{base}/n:CEP", @note).present?)].reject(&:blank?).join(' - ')
    end

    # A fonte padrão do PDF (Windows-1252) não tem todos os caracteres: troca os que não existem por "?".
    def txt(value)
      value.to_s.encode('Windows-1252', invalid: :replace, undef: :replace, replace: '?').encode('UTF-8')
    end

    def document(value)
      digits = value.to_s.gsub(/\D/, '')
      case digits.length
      when 14 then digits.sub(/(\d{2})(\d{3})(\d{3})(\d{4})(\d{2})/, '\1.\2.\3/\4-\5')
      when 11 then digits.sub(/(\d{3})(\d{3})(\d{3})(\d{2})/, '\1.\2.\3-\4')
      else digits
      end
    end

    def zip(value)
      value.to_s.gsub(/\D/, '').sub(/\A(\d{5})(\d{3})\z/, '\1-\2')
    end

    def date(value)
      value.present? ? value[0, 10].split('-').reverse.join('/') : ''
    end

    def datetime(value)
      value.present? && value.length >= 19 ? "#{date(value)} #{value[11, 8]}" : date(value)
    end
  end
end
