require 'prawn'
require 'prawn/table'

Prawn::Fonts::AFM.hide_m17n_warning = true

module Nfe
  # DANFE retrato (A4) no leiaute do Manual de Orientação do Contribuinte, montado a partir do XML guardado na nota
  # (o nfeProc autorizado, ou o XML assinado quando ainda não há protocolo). Não consulta banco nem SEFAZ.
  class Danfe
    NS = { 'n' => 'http://www.portalfiscal.inf.br/nfe' }.freeze
    WIDTH = 555.28
    LABEL_SIZE = 5.5
    VALUE_SIZE = 8
    ROW = 21
    BOTTOM_BLOCK = 92
    CONTINUATION_HEADER = 96
    INK = '000000'.freeze
    WATERMARK = 'B0B0B0'.freeze

    FREIGHT_MODES = {
      '0' => '0-Por conta do Remet', '1' => '1-Por conta do Dest', '2' => '2-Por conta de Terceiros',
      '3' => '3-Próprio por conta Remet', '4' => '4-Próprio por conta Dest', '9' => '9-Sem Ocorrência de Transp.'
    }.freeze
    PAYMENT_METHODS = {
      '01' => 'Dinheiro', '02' => 'Cheque', '03' => 'Cartão de Crédito', '04' => 'Cartão de Débito', '05' => 'Crédito Loja',
      '10' => 'Vale Alimentação', '11' => 'Vale Refeição', '12' => 'Vale Presente', '13' => 'Vale Combustível',
      '15' => 'Boleto Bancário', '16' => 'Depósito Bancário', '17' => 'PIX', '18' => 'Transferência bancária',
      '19' => 'Programa de fidelidade', '90' => 'Sem pagamento', '99' => 'Outros'
    }.freeze

    def initialize(xml, cancelled: false)
      @doc = Nokogiri::XML(xml)
      @cancelled = cancelled
    end

    def filename
      "DANFE-#{access_key}.pdf"
    end

    def render
      @pdf = Prawn::Document.new(page_size: 'A4', margin: [20, 20, 20, 20],
                                 info: { Title: "DANFE #{number_label}", Creator: 'Honey Chase' })
      @pdf.font 'Helvetica'
      @pdf.default_leading 0

      receipt_stub
      header(full: true)
      continuation_header
      operation_rows
      recipient
      payments
      tax_totals
      carrier
      items
      additional_info
      page_marks
      @pdf.render
    end

    private

    # ---------- leitura do XML ----------

    def at(path, node = @doc)
      node.at_xpath(path, NS)&.text.to_s.strip
    end

    def inf
      @inf ||= @doc.at_xpath('//n:infNFe', NS)
    end

    def access_key
      inf['Id'].to_s.delete_prefix('NFe')
    end

    def homologation?
      at('//n:ide/n:tpAmb') == '2'
    end

    def authorized?
      %w[100 150].include?(at('//n:protNFe/n:infProt/n:cStat'))
    end

    def number_label
      format('%09d', at('//n:ide/n:nNF').to_i).scan(/\d{3}/).join('.')
    end

    def series_label
      format('%03d', at('//n:ide/n:serie').to_i)
    end

    # Valor do total da nota; o que não veio no XML sai como zero, como o DANFE pede.
    def total(tag)
      at("//n:total/n:ICMSTot/n:#{tag}").presence || '0'
    end

    # ---------- formatação ----------

    # A fonte padrão do PDF (Windows-1252) não tem todos os caracteres: troca os que não existem por "?".
    def txt(value)
      value.to_s.gsub(/<br\s*\/?>/i, "\n").encode('Windows-1252', invalid: :replace, undef: :replace, replace: '?')
           .encode('UTF-8')
    end

    def money(value, decimals = 2)
      return '' if value.blank?

      int, frac = format("%.#{decimals}f", BigDecimal(value.to_s)).split('.')
      sign = int.start_with?('-') ? '-' : ''
      grouped = int.delete('-').reverse.scan(/\d{1,3}/).join('.').reverse
      decimals.zero? ? "#{sign}#{grouped}" : "#{sign}#{grouped},#{frac}"
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

    def phone(value)
      digits = value.to_s.gsub(/\D/, '')
      case digits.length
      when 11 then digits.sub(/(\d{2})(\d{5})(\d{4})/, '(\1) \2-\3')
      when 10 then digits.sub(/(\d{2})(\d{4})(\d{4})/, '(\1) \2-\3')
      else digits
      end
    end

    def date(value)
      value.present? ? value[0, 10].split('-').reverse.join('/') : ''
    end

    def time(value)
      value.present? && value.length >= 19 ? value[11, 8] : ''
    end

    def key_label
      access_key.scan(/\d{4}/).join(' ')
    end

    # ---------- desenho ----------

    # Caixa com rótulo pequeno no alto e valor embaixo; x e y relativos ao topo atual (cursor).
    def box(x, width, label, value = '', height: ROW, align: :left, size: VALUE_SIZE, style: :normal, top: @pdf.cursor)
      @pdf.stroke_rectangle([x, top], width, height)
      @pdf.text_box txt(label), at: [x + 2, top - 1.5], width: width - 4, height: 7, size: LABEL_SIZE
      @pdf.text_box txt(value), at: [x + 2, top - 8.5], width: width - 4, height: height - 9, size: size, align: align,
                                style: style, overflow: :shrink_to_fit, min_font_size: 5
    end

    # Linha de caixas que ocupa a largura toda; cada coluna é [rótulo, valor, largura relativa, opções].
    def row(columns, height: ROW)
      total_weight = columns.sum { |c| c[2] }
      x = 0
      columns.each_with_index do |(label, value, weight, opts), index|
        width = index == columns.size - 1 ? WIDTH - x : (WIDTH * weight / total_weight).round(2)
        box(x, width, label, value, height: height, **(opts || {}))
        x += width
      end
      @pdf.move_down height
    end

    def section(title)
      @pdf.move_down 3
      @pdf.text txt(title), size: 6.5, style: :bold
      @pdf.move_down 1
    end

    def receipt_stub
      top = @pdf.cursor
      stub_width = WIDTH - 110
      emitter = at('//n:emit/n:xNome')
      text = "RECEBEMOS DE #{emitter} OS PRODUTOS E/OU SERVIÇOS CONSTANTES DA NOTA FISCAL ELETRÔNICA INDICADA ABAIXO. " \
             "EMISSÃO: #{date(at('//n:ide/n:dhEmi'))} VALOR TOTAL: R$ #{money(total('vNF'))} " \
             "DESTINATÁRIO: #{at('//n:dest/n:xNome')} - #{recipient_address}"
      @pdf.stroke_rectangle([0, top], stub_width, 20)
      @pdf.text_box txt(text), at: [2, top - 2], width: stub_width - 4, height: 17, size: 6, overflow: :shrink_to_fit
      box(0, 110, 'DATA DE RECEBIMENTO', top: top - 20, height: 20)
      box(110, stub_width - 110, 'IDENTIFICAÇÃO E ASSINATURA DO RECEBEDOR', top: top - 20, height: 20)
      @pdf.stroke_rectangle([stub_width, top], 110, 40)
      @pdf.text_box txt("NF-e\nNº #{number_label}\nSÉRIE #{series_label}"), at: [stub_width, top - 4], width: 110,
                                                                                  height: 35, size: 9, style: :bold, align: :center
      @pdf.move_down 44
      @pdf.dash(2, space: 2)
      @pdf.stroke_horizontal_line 0, WIDTH
      @pdf.undash
      @pdf.move_down 5
    end

    def recipient_address
      [at('//n:dest/n:enderDest/n:xLgr'), at('//n:dest/n:enderDest/n:nro'), at('//n:dest/n:enderDest/n:xBairro'),
       "#{at('//n:dest/n:enderDest/n:xMun')}/#{at('//n:dest/n:enderDest/n:UF')}"].reject(&:blank?).join(', ')
    end

    # Cabeçalho: emitente, quadro DANFE e chave de acesso. full: false é a versão das folhas seguintes.
    def header(full:)
      top = @pdf.cursor
      height = full ? 112 : 92
      emit_width = 228
      danfe_width = 100
      key_x = emit_width + danfe_width
      key_width = WIDTH - key_x

      @pdf.stroke_rectangle([0, top], emit_width, height)
      @pdf.text_box 'IDENTIFICAÇÃO DO EMITENTE', at: [2, top - 2], width: emit_width - 4, size: LABEL_SIZE
      emit_text = [at('//n:emit/n:xNome'), emitter_address,
                   "#{at('//n:emit/n:enderEmit/n:xMun')} - #{at('//n:emit/n:enderEmit/n:UF')}  CEP: #{zip(at('//n:emit/n:enderEmit/n:CEP'))}",
                   ("Fone: #{phone(at('//n:emit/n:enderEmit/n:fone'))}" if at('//n:emit/n:enderEmit/n:fone').present?)].compact
      @pdf.text_box txt(emit_text.first), at: [6, top - 16], width: emit_width - 12, height: 30, size: 10, style: :bold,
                                          align: :center, overflow: :shrink_to_fit
      @pdf.text_box txt(emit_text.drop(1).join("\n")), at: [6, top - 48], width: emit_width - 12, height: height - 52,
                                                       size: 7.5, align: :center, overflow: :shrink_to_fit

      @pdf.stroke_rectangle([emit_width, top], danfe_width, height)
      @pdf.text_box 'DANFE', at: [emit_width, top - 6], width: danfe_width, size: 13, style: :bold, align: :center
      @pdf.text_box txt("DOCUMENTO AUXILIAR DA\nNOTA FISCAL ELETRÔNICA"), at: [emit_width + 2, top - 22], width: danfe_width - 4,
                                                                      size: 6, align: :center
      @pdf.text_box txt("0 - ENTRADA\n1 - SAÍDA"), at: [emit_width + 12, top - 42], width: 50, size: 6.5
      @pdf.stroke_rectangle([emit_width + 68, top - 41], 16, 16)
      @pdf.text_box at('//n:ide/n:tpNF'), at: [emit_width + 68, top - 44], width: 16, size: 10, style: :bold, align: :center
      @pdf.text_box txt("Nº #{number_label}\nSÉRIE #{series_label}"), at: [emit_width, top - 62], width: danfe_width,
                                                                      size: 8.5, style: :bold, align: :center
      @sheet_marks ||= []
      # Posição absoluta: o total de folhas só é conhecido no fim, quando o texto é escrito.
      @sheet_marks << [@pdf.page_number, @pdf.bounds.absolute_left + emit_width, @pdf.bounds.absolute_bottom + top - 85, danfe_width]

      barcode(key_x + 8, top - 4, key_width - 16, 32)
      box(key_x, key_width, 'CHAVE DE ACESSO', key_label, top: top - 40, height: 20, align: :center, size: 8.5, style: :bold)
      consult = 'Consulta de autenticidade no portal nacional da NF-e www.nfe.fazenda.gov.br/portal ou no site da Sefaz Autorizadora'
      @pdf.stroke_rectangle([key_x, top - 60], key_width, height - 60)
      @pdf.text_box txt(consult), at: [key_x + 4, top - 66], width: key_width - 8, height: height - 66, size: 7.5,
                                  align: :center, overflow: :shrink_to_fit
      @pdf.move_down height
    end

    # Folhas seguintes: a margem de cima cresce para caber o cabeçalho reduzido, desenhado a cada folha nova.
    def continuation_header
      @pdf.state.page.margins[:top] += CONTINUATION_HEADER
      @pdf.renderer.on_page_create do
        @pdf.bounding_box([0, @pdf.bounds.top + CONTINUATION_HEADER], width: WIDTH, height: CONTINUATION_HEADER) do
          header(full: false)
        end
      end
    end

    def emitter_address
      [at('//n:emit/n:enderEmit/n:xLgr'), at('//n:emit/n:enderEmit/n:nro'), at('//n:emit/n:enderEmit/n:xCpl'),
       at('//n:emit/n:enderEmit/n:xBairro')].reject(&:blank?).join(', ')
    end

    def barcode(x, top, width, height)
      widths = Code128.widths(access_key)
      module_width = width / widths.sum.to_f
      position = x
      @pdf.fill_color INK
      widths.each_with_index do |w, index|
        @pdf.fill_rectangle([position, top], w * module_width, height) if index.even?
        position += w * module_width
      end
    end

    def operation_rows
      protocol = if authorized?
                   prot = '//n:protNFe/n:infProt'
                   "#{at("#{prot}/n:nProt")} - #{date(at("#{prot}/n:dhRecbto"))} #{time(at("#{prot}/n:dhRecbto"))}"
                 else
                   'NOTA NÃO AUTORIZADA - SEM VALOR FISCAL'
                 end
      row([['NATUREZA DA OPERAÇÃO', at('//n:ide/n:natOp'), 59],
           ['PROTOCOLO DE AUTORIZAÇÃO DE USO', protocol, 41, { align: :center, style: :bold }]])
      row([['INSCRIÇÃO ESTADUAL', at('//n:emit/n:IE'), 33],
           ['INSCRIÇÃO ESTADUAL DO SUBST. TRIBUT.', at('//n:emit/n:IEST'), 33],
           ['CNPJ', document(at('//n:emit/n:CNPJ')), 34]])
    end

    def recipient
      section('DESTINATÁRIO / REMETENTE')
      dest = '//n:dest'
      ender = "#{dest}/n:enderDest"
      street = [at("#{ender}/n:xLgr"), at("#{ender}/n:nro"), at("#{ender}/n:xCpl")].reject(&:blank?).join(', ')
      row([['NOME / RAZÃO SOCIAL', at("#{dest}/n:xNome"), 62],
           ['CNPJ / CPF', document(at("#{dest}/n:CNPJ").presence || at("#{dest}/n:CPF")), 22, { align: :center }],
           ['DATA DA EMISSÃO', date(at('//n:ide/n:dhEmi')), 16, { align: :center }]])
      row([['ENDEREÇO', street, 47], ['BAIRRO / DISTRITO', at("#{ender}/n:xBairro"), 24],
           ['CEP', zip(at("#{ender}/n:CEP")), 13, { align: :center }],
           ['DATA DA SAÍDA/ENTRADA', date(at('//n:ide/n:dhSaiEnt')), 16, { align: :center }]])
      row([['MUNICÍPIO', at("#{ender}/n:xMun"), 37], ['UF', at("#{ender}/n:UF"), 6, { align: :center }],
           ['FONE / FAX', phone(at("#{ender}/n:fone")), 19], ['INSCRIÇÃO ESTADUAL', at("#{dest}/n:IE"), 22],
           ['HORA DA SAÍDA/ENTRADA', time(at('//n:ide/n:dhSaiEnt')), 16, { align: :center }]])
    end

    def payments
      details = @doc.xpath('//n:pag/n:detPag', NS)
      return if details.empty?

      section('PAGAMENTO')
      columns = details.first(6).map do |detail|
        method = at('n:tPag', detail)
        label = method == '99' && at('n:xPag', detail).present? ? at('n:xPag', detail) : PAYMENT_METHODS.fetch(method, method)
        [label.upcase, "R$ #{money(at('n:vPag', detail))}", 1]
      end
      row(columns)
    end

    def tax_totals
      section('CÁLCULO DO IMPOSTO')
      right = { align: :right }
      row([['BASE DE CÁLC. DO ICMS', money(total('vBC')), 1, right], ['VALOR DO ICMS', money(total('vICMS')), 1, right],
           ['BASE DE CÁLC. ICMS S.T.', money(total('vBCST')), 1, right], ['VALOR DO ICMS SUBST.', money(total('vST')), 1, right],
           ['V. IMP. IMPORTAÇÃO', money(total('vII')), 1, right], ['V. ICMS UF REMET.', money(total('vICMSUFRemet')), 1, right],
           ['V. FCP UF DEST.', money(total('vFCPUFDest')), 1, right], ['VALOR DO PIS', money(total('vPIS')), 1, right],
           ['V. TOTAL PRODUTOS', money(total('vProd')), 1, right]])
      row([['VALOR DO FRETE', money(total('vFrete')), 1, right], ['VALOR DO SEGURO', money(total('vSeg')), 1, right],
           ['DESCONTO', money(total('vDesc')), 1, right], ['OUTRAS DESPESAS', money(total('vOutro')), 1, right],
           ['VALOR TOTAL IPI', money(total('vIPI')), 1, right], ['V. ICMS UF DEST.', money(total('vICMSUFDest')), 1, right],
           ['V. TOT. TRIB.', money(total('vTotTrib')), 1, right], ['VALOR DA COFINS', money(total('vCOFINS')), 1, right],
           ['V. TOTAL DA NOTA', money(total('vNF')), 1, { align: :right, style: :bold }]])
    end

    def carrier
      section('TRANSPORTADOR / VOLUMES TRANSPORTADOS')
      t = '//n:transp/n:transporta'
      vol = '//n:transp/n:vol'
      row([['NOME / RAZÃO SOCIAL', at("#{t}/n:xNome"), 32], ['FRETE', FREIGHT_MODES.fetch(at('//n:transp/n:modFrete'), ''), 19],
           ['CÓDIGO ANTT', at('//n:transp/n:veicTransp/n:RNTC'), 11], ['PLACA DO VEÍCULO', at('//n:transp/n:veicTransp/n:placa'), 11],
           ['UF', at('//n:transp/n:veicTransp/n:UF'), 5, { align: :center }],
           ['CNPJ / CPF', document(at("#{t}/n:CNPJ").presence || at("#{t}/n:CPF")), 22, { align: :center }]])
      row([['ENDEREÇO', at("#{t}/n:xEnder"), 44], ['MUNICÍPIO', at("#{t}/n:xMun"), 29],
           ['UF', at("#{t}/n:UF"), 5, { align: :center }], ['INSCRIÇÃO ESTADUAL', at("#{t}/n:IE"), 22]])
      row([['QUANTIDADE', at("#{vol}/n:qVol"), 1], ['ESPÉCIE', at("#{vol}/n:esp"), 1], ['MARCA', at("#{vol}/n:marca"), 1],
           ['NUMERAÇÃO', at("#{vol}/n:nVol"), 1], ['PESO BRUTO', money(at("#{vol}/n:pesoB").presence, 3), 1, { align: :right }],
           ['PESO LÍQUIDO', money(at("#{vol}/n:pesoL").presence, 3), 1, { align: :right }]])
    end

    ITEM_COLUMNS = [
      ['CÓDIGO PRODUTO', 52], ['DESCRIÇÃO DO PRODUTO / SERVIÇO', nil], ['NCM/SH', 34], ['O/CST', 22], ['CFOP', 22],
      ['UN', 18], ['QUANT.', 32], ['VALOR UNIT.', 36], ['VALOR TOTAL', 38], ['VALOR DESC.', 32], ['B.CÁLC. ICMS', 38],
      ['VALOR ICMS', 32], ['VALOR IPI', 28], ['ALÍQ. ICMS', 22], ['ALÍQ. IPI', 22]
    ].freeze

    def items
      section('DADOS DOS PRODUTOS / SERVIÇOS')
      fixed = ITEM_COLUMNS.sum { |_, w| w.to_i }
      widths = ITEM_COLUMNS.map { |_, w| w || (WIDTH - fixed) }
      rows = [ITEM_COLUMNS.map { |label, _| txt(label) }] + @doc.xpath('//n:det', NS).map { |det| item_row(det) }

      @pdf.table(rows, column_widths: widths, header: true, width: WIDTH,
                       cell_style: { size: 6, padding: [2, 2, 2, 2], border_width: 0.5, inline_format: false }) do |t|
        t.row(0).style(size: 5, font_style: :bold, align: :center, valign: :center)
        t.columns(2..14).style(align: :center)
        t.columns(6..14).rows(1..(rows.size - 1)).style(align: :right)
      end
    end

    def item_row(det)
      prod = det.at_xpath('n:prod', NS)
      icms = det.at_xpath('n:imposto/n:ICMS/*', NS)
      ipi = det.at_xpath('n:imposto/n:IPI/n:IPITrib', NS)
      cst = icms ? "#{at('n:orig', icms)}#{at('n:CST', icms).presence || at('n:CSOSN', icms)}" : ''
      [at('n:cProd', prod), at('n:xProd', prod), at('n:NCM', prod), cst, at('n:CFOP', prod), at('n:uCom', prod),
       money(at('n:qCom', prod), 4), money(at('n:vUnCom', prod), 4), money(at('n:vProd', prod)),
       money(at('n:vDesc', prod).presence || '0'), money(icms && at('n:vBC', icms).presence || '0'),
       money(icms && at('n:vICMS', icms).presence || '0'), money(ipi && at('n:vIPI', ipi).presence || '0'),
       money(icms && at('n:pICMS', icms).presence || '0'), money(ipi && at('n:pIPI', ipi).presence || '0')]
        .map { |value| txt(value) }
    end

    def additional_info
      @pdf.start_new_page if @pdf.cursor < BOTTOM_BLOCK + 14
      @pdf.move_cursor_to BOTTOM_BLOCK + 10
      section('DADOS ADICIONAIS')
      top = @pdf.cursor
      info_width = WIDTH * 0.66
      box(0, info_width, 'INFORMAÇÕES COMPLEMENTARES', complementary_info, height: top, size: 6.5, top: top)
      box(info_width, WIDTH - info_width, 'RESERVADO AO FISCO', '', height: top, top: top)
    end

    def complementary_info
      lines = []
      lines << "Inf. fisco: #{at('//n:infAdic/n:infAdFisco')}" if at('//n:infAdic/n:infAdFisco').present?
      lines << at('//n:infAdic/n:infCpl') if at('//n:infAdic/n:infCpl').present?
      if BigDecimal(total('vICMSUFDest')).positive?
        lines << "DIFAL - ICMS p/ UF de destino: R$ #{money(total('vICMSUFDest'))}; FCP UF destino: R$ #{money(total('vFCPUFDest'))}"
      end
      ibs = at('//n:total/n:IBSCBSTot/n:gIBS/n:vIBS')
      lines << "IBS: R$ #{money(ibs)}; CBS: R$ #{money(at('//n:total/n:IBSCBSTot/n:gCBS/n:vCBS'))}" if ibs.present?
      lines.join("\n")
    end

    # Folha x/y no quadro DANFE, cabeçalho nas folhas seguintes e a marca d'água quando a nota não vale.
    def page_marks
      pages = @pdf.page_count
      @sheet_marks.each do |page, x, y, width|
        @pdf.go_to_page(page)
        @pdf.canvas { @pdf.text_box "FOLHA #{page}/#{pages}", at: [x, y], width: width, size: 7, align: :center }
      end
      watermark_text = watermark
      return unless watermark_text

      (1..pages).each do |page|
        @pdf.go_to_page(page)
        @pdf.transparent(0.25) do
          @pdf.fill_color WATERMARK
          @pdf.rotate(35, origin: [WIDTH / 2, 380]) do
            @pdf.text_box watermark_text, at: [0, 430], width: WIDTH, height: 120, size: 40, style: :bold, align: :center
          end
          @pdf.fill_color INK
        end
      end
    end

    def watermark
      return 'CANCELADA' if @cancelled
      return "SEM VALOR FISCAL\nHOMOLOGAÇÃO" if homologation?

      "SEM VALOR FISCAL\nNÃO AUTORIZADA" unless authorized?
    end
  end
end
