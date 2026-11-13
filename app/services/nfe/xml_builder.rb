require 'nokogiri'
require 'bigdecimal'

module Nfe
  # Monta o XML da NF-e (modelo 55, layout 4.00) e a chave de acesso.
  # Função pura: não acessa banco, rede nem certificado. A assinatura é feita por Nfe::Signer.
  class XmlBuilder
    class Error < StandardError; end

    Result = Struct.new(:xml, :access_key, :total, keyword_init: true)

    NAMESPACE = 'http://www.portalfiscal.inf.br/nfe'.freeze
    VERSION = '4.00'.freeze
    HOMOLOGATION_TEXT = 'NF-E EMITIDA EM AMBIENTE DE HOMOLOGACAO - SEM VALOR FISCAL'.freeze
    TIME_ZONE = 'America/Sao_Paulo'.freeze

    SIMPLES_CSOSN = %w[102 103 300 400].freeze
    NORMAL_ICMS_CST = %w[00 40 41 50].freeze
    PIS_COFINS_TAXED = %w[01 02].freeze
    PIS_COFINS_NOT_TAXED = %w[04 05 06 07 08 09].freeze
    PIS_COFINS_OTHER = %w[49 99].freeze
    ZERO = BigDecimal('0')
    # indPres que exigem informar se houve intermediador (marketplace).
    REMOTE_PRESENCES = %w[2 3 4 9].freeze
    # Pagamento padrão do B2B: sem pagamento informado na nota.
    NO_PAYMENT = [{ method: '90', amount: 0 }].freeze
    # Reforma tributária, ano de teste (2026): IBS e CBS destacados com alíquotas simbólicas, sem somar ao total.
    # Padrão de quando a natureza não informa nada (tax[:ibs_cbs], ver OperationNature#tax_rules).
    IBS_CBS = { cst: '000', class: '000001', ibs_uf: BigDecimal('0.1'), ibs_mun: ZERO, cbs: BigDecimal('0.9') }.freeze
    # Transferência entre estabelecimentos do mesmo titular: não incidência de IBS/CBS (LC 214/2025, art. 6º).
    # A SVRS já exige o grupo IBSCBS; vai só com CST e cClassTrib, sem valores.
    IBS_CBS_TRANSFER = { cst: '410', class: '410002' }.freeze

    def self.access_key_check_digit(digits43)
      weights = [2, 3, 4, 5, 6, 7, 8, 9]
      sum = digits43.reverse.chars.each_with_index.sum { |char, index| char.to_i * weights[index % 8] }
      remainder = sum % 11
      remainder < 2 ? 0 : 11 - remainder
    end

    # Venda ao consumidor final pela internet: final_consumer: true, presence: '2', payments e frete/desconto
    # por item (:freight e :discount). Sem essas opções a nota sai como B2B (contribuinte, sem pagamento).
    # tax: regras de tributação (OperationNature#tax_rules); sem ela valem as situações cadastradas na empresa.
    def initialize(company:, recipient:, items:, number:, series:, operation_nature:, issued_at:, cnf: nil,
                   final_consumer: false, presence: '0', freight_mode: '9', payments: nil, additional_info: nil,
                   fisco_info: nil, purpose: 1, tax: nil, ibs_cbs_exempt: nil, environment: nil, duplicates: nil)
      @company = company
      # Parcelas a receber (grupo cobr): [{ number:, due: Date, value: }]. Sem elas, a nota não tem cobrança.
      @duplicates = Array(duplicates)
      # Ambiente da nota; sem ele, o da empresa.
      @environment = (environment || company.environment).to_s
      @ibs_cbs_exempt = ibs_cbs_exempt
      @tax = tax || { icms_situation: company.icms_situation, pis_cst: company.pis_cst, cofins_cst: company.cofins_cst }
      @fisco_info = fisco_info
      @purpose = purpose
      @final_consumer = final_consumer
      @presence = presence.to_s
      @freight_mode = freight_mode.to_s
      @payments = payments.presence || NO_PAYMENT
      @additional_info = additional_info
      @recipient = recipient
      @items = items
      @number = number.to_i
      @series = series.to_i
      @operation_nature = operation_nature
      @issued_at = issued_at.in_time_zone(TIME_ZONE)
      @cnf = cnf
    end

    def call
      validate!
      key = build_access_key
      total = note_total

      builder = Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
        xml.NFe(xmlns: NAMESPACE) do
          xml.infNFe(Id: "NFe#{key}", versao: VERSION) do
            build_ide(xml, key)
            build_emit(xml)
            build_dest(xml)
            @items.each_with_index { |item, index| build_det(xml, item, index) }
            build_total(xml, total)
            xml.transp { xml.modFrete @freight_mode }
            build_cobr(xml, total)
            build_pag(xml)
            build_inf_adic(xml)
            build_resp_tec(xml)
          end
        end
      end

      Result.new(xml: builder.doc.root.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML),
                 access_key: key, total: total)
    end

    private

    def homologation?
      @environment == 'homologacao'
    end

    def validate!
      raise Error, 'A nota precisa ter pelo menos um item.' if @items.blank?
      raise Error, 'Inscrição Estadual da empresa ausente.' if @company.state_registration.blank?
      raise Error, 'Código IBGE do município da empresa ausente.' if @company.city_ibge_code.blank?
      raise Error, 'Documento (CNPJ/CPF) do destinatário ausente.' unless [11, 14].include?(Cnpj.digits(@recipient[:document]).length)
      raise Error, 'Código IBGE do destinatário ausente.' if @recipient[:city_ibge_code].blank?
      raise Error, 'UF do destinatário inválida.' unless Company::STATES.key?(@recipient[:state])

      @items.each do |item|
        raise Error, "NCM ausente para o item #{item[:code]}." unless item[:ncm].to_s.match?(/\A\d{8}\z/)
      end
      validate_tax_situations!
      validate_difal!
    end

    def validate_tax_situations!
      icms = @tax[:icms_situation]
      supported = normal_regime? ? NORMAL_ICMS_CST : SIMPLES_CSOSN
      raise Error, "Situação tributária de ICMS #{icms} não suportada para este regime." unless supported.include?(icms)
      raise Error, 'Alíquota de ICMS ausente para ICMS tributado.' if icms_taxed? && rate(:icms_rate).zero?

      [@tax[:pis_cst], @tax[:cofins_cst]].each do |cst|
        next if (PIS_COFINS_TAXED + PIS_COFINS_NOT_TAXED + PIS_COFINS_OTHER).include?(cst)

        raise Error, "CST de PIS/COFINS #{cst} não suportado."
      end
    end

    # Venda interestadual a consumidor não contribuinte no Regime Normal: sem o DIFAL a SEFAZ rejeita (694).
    def validate_difal!
      return unless interstate_final_consumer? && normal_regime?
      raise Error, 'Venda a consumidor de outra UF exige DIFAL: ative o DIFAL na natureza de operação.' unless @tax[:difal]
      return unless icms_taxed?
      raise Error, "Alíquota interna de ICMS da UF #{@recipient[:state]} ausente na natureza de operação." if dest_rates[:internal].zero?
    end

    def normal_regime?
      @company.tax_regime == 3
    end

    def icms_taxed?
      normal_regime? && @tax[:icms_situation] == '00'
    end

    def rate(key)
      BigDecimal((@tax[key].presence || 0).to_s)
    end

    def interstate_final_consumer?
      @final_consumer && id_dest == '2' && @recipient[:ie_indicator].to_i == 9
    end

    def difal?
      interstate_final_consumer? && normal_regime? && icms_taxed? && @tax[:difal]
    end

    def dest_rates
      @dest_rates ||= @tax[:uf_rates] ? @tax[:uf_rates].call(@recipient[:state]) : { internal: ZERO, fcp: ZERO }
    end

    # Base, alíquota e valor de cada tributo por item, calculados uma vez e usados no item e no total.
    def item_taxes
      @item_taxes ||= @items.each_with_index.map do |item, index|
        base = line_totals[index] - money(item[:discount]) + money(item[:freight])
        taxes = { base: base, icms_base: ZERO, icms_rate: ZERO, icms: ZERO }
        if icms_taxed?
          icms_rate = item_icms_rate(item)
          taxes.merge!(icms_base: base, icms_rate: icms_rate, icms: percent(base, icms_rate))
        end
        taxes[:difal] = difal_tax(base, taxes[:icms_rate]) if difal?
        pis_cofins_base = @tax[:exclude_icms_from_pis_cofins_base] ? base - taxes[:icms] : base
        taxes[:pis] = pis_cofins_tax(@tax[:pis_cst], pis_cofins_base, rate(:pis_rate))
        taxes[:cofins] = pis_cofins_tax(@tax[:cofins_cst], pis_cofins_base, rate(:cofins_rate))
        taxes[:ibs_cbs] = ibs_cbs_tax(base, taxes) if ibs_cbs?
        taxes
      end
    end

    # Mesma UF: alíquota da natureza. Outra UF: tabela 12%/7%, ou a alíquota da exceção do ICMS (icms_rate_fixed),
    # menos para mercadoria importada, que fica sempre nos 4% da Resolução do Senado 13/2012.
    def item_icms_rate(item)
      return rate(:icms_rate) if id_dest != '2'

      interstate = IcmsRates.interstate(@company.state, @recipient[:state], item[:origin])
      return interstate if !@tax[:icms_rate_fixed] || IcmsRates::IMPORTED_ORIGINS.include?(item[:origin].to_i)

      rate(:icms_rate)
    end

    # DIFAL por base dupla, igual ao Tiny: o valor é "inflado" pela alíquota interna + FCP do destino
    # e o destino recebe o ICMS interno sobre essa base menos o ICMS interestadual já destacado.
    def difal_tax(base, inter_rate)
      internal = dest_rates[:internal]
      fcp_rate = dest_rates[:fcp]
      dest_base = (base / (1 - ((internal + fcp_rate) / 100))).round(2)
      dest = ((dest_base * internal / 100) - (base * inter_rate / 100)).round(2)
      { base: dest_base, fcp_rate: fcp_rate, internal_rate: internal, inter_rate: inter_rate,
        fcp: percent(dest_base, fcp_rate), dest: [dest, ZERO].max }
    end

    # Regra do IBS/CBS: a da natureza (modo, CST, cClassTrib e alíquotas) sobre o padrão. No modo "auto" a
    # nota de transferência (ibs_cbs_exempt) vai só com CST e cClassTrib de não incidência.
    def ibs_cbs_rule
      @ibs_cbs_rule ||= begin
        rule = IBS_CBS.merge(mode: 'auto').merge((@tax[:ibs_cbs] || {}).compact)
        rule[:mode] == 'auto' && @ibs_cbs_exempt ? rule.merge(@ibs_cbs_exempt).merge(mode: 'no_values') : rule
      end
    end

    # Com valores: no "auto", venda a consumidor no Regime Normal (como o Tiny já emite); no "taxed", toda nota
    # do Regime Normal.
    def ibs_cbs?
      return false unless normal_regime?

      case ibs_cbs_rule[:mode]
      when 'auto' then @final_consumer
      when 'taxed' then true
      else false
      end
    end

    def ibs_cbs_exempt?
      ibs_cbs_rule[:mode] == 'no_values'
    end

    # A base do IBS/CBS exclui ICMS (próprio e DIFAL/FCP), PIS e COFINS.
    def ibs_cbs_tax(base, taxes)
      difal = taxes[:difal] || {}
      ibs_base = base - taxes[:icms] - taxes[:pis][:value] - taxes[:cofins][:value] - (difal[:dest] || ZERO) - (difal[:fcp] || ZERO)
      ibs_uf = percent(ibs_base, ibs_cbs_rule[:ibs_uf])
      ibs_mun = percent(ibs_base, ibs_cbs_rule[:ibs_mun])
      { base: ibs_base, ibs_uf: ibs_uf, ibs_mun: ibs_mun, ibs: ibs_uf + ibs_mun, cbs: percent(ibs_base, ibs_cbs_rule[:cbs]) }
    end

    def pis_cofins_tax(cst, base, rate)
      return { base: ZERO, rate: ZERO, value: ZERO } unless PIS_COFINS_TAXED.include?(cst)

      { base: base, rate: rate, value: percent(base, rate) }
    end

    def percent(base, rate)
      (base * rate / 100).round(2)
    end

    def sum_tax(&block)
      item_taxes.sum(ZERO, &block)
    end

    def build_access_key
      digits = [
        @company.state_code,
        @issued_at.strftime('%y%m'),
        @company.cnpj,
        '55',
        format('%03d', @series),
        format('%09d', @number),
        '1',
        cnf
      ].join
      digits + self.class.access_key_check_digit(digits).to_s
    end

    def cnf
      return @cnf.to_s.rjust(8, '0') if @cnf

      loop do
        candidate = format('%08d', SecureRandom.random_number(100_000_000))
        return candidate unless candidate == format('%08d', @number)
      end
    end

    def id_dest
      @recipient[:state] == @company.state ? '1' : '2'
    end

    def build_ide(xml, key)
      xml.ide do
        xml.cUF @company.state_code
        xml.cNF key[35, 8]
        xml.natOp @operation_nature
        xml.mod '55'
        xml.serie @series.to_s
        xml.nNF @number.to_s
        xml.dhEmi @issued_at.strftime('%Y-%m-%dT%H:%M:%S%:z')
        xml.tpNF '1'
        xml.idDest id_dest
        xml.cMunFG @company.city_ibge_code
        xml.tpImp '1'
        xml.tpEmis '1'
        xml.cDV key[43]
        xml.tpAmb(homologation? ? '2' : '1')
        xml.finNFe @purpose.to_s
        xml.indFinal(@final_consumer ? '1' : '0')
        xml.indPres @presence
        xml.indIntermed '0' if REMOTE_PRESENCES.include?(@presence)
        xml.procEmi '0'
        xml.verProc 'Honey 1.0'
      end
    end

    def build_emit(xml)
      xml.emit do
        xml.CNPJ @company.cnpj
        xml.xNome @company.legal_name
        xml.xFant @company.trade_name if @company.trade_name.present?
        xml.enderEmit do
          xml.xLgr @company.street
          xml.nro @company.number
          xml.xCpl @company.complement if @company.complement.present?
          xml.xBairro @company.neighbourhood
          xml.cMun @company.city_ibge_code
          xml.xMun @company.city
          xml.UF @company.state
          xml.CEP Cnpj.digits(@company.zip)
          xml.cPais '1058'
          xml.xPais 'BRASIL'
          xml.fone Cnpj.digits(@company.phone) if @company.phone.present?
        end
        xml.IE Cnpj.digits(@company.state_registration)
        # IM e CNAE só são válidos juntos no layout.
        if @company.municipal_registration.present? && @company.cnae.present?
          xml.IM @company.municipal_registration
          xml.CNAE Cnpj.digits(@company.cnae)
        end
        xml.CRT @company.tax_regime.to_s
      end
    end

    def build_dest(xml)
      document = Cnpj.digits(@recipient[:document])
      xml.dest do
        document.length == 14 ? xml.CNPJ(document) : xml.CPF(document)
        xml.xNome(homologation? ? HOMOLOGATION_TEXT : @recipient[:name])
        xml.enderDest do
          xml.xLgr @recipient[:street]
          xml.nro @recipient[:number]
          xml.xCpl @recipient[:complement] if @recipient[:complement].present?
          xml.xBairro @recipient[:neighbourhood]
          xml.cMun @recipient[:city_ibge_code]
          xml.xMun @recipient[:city]
          xml.UF @recipient[:state]
          xml.CEP Cnpj.digits(@recipient[:zip])
          xml.cPais '1058'
          xml.xPais 'BRASIL'
          xml.fone Cnpj.digits(@recipient[:phone]) if @recipient[:phone].present?
        end
        xml.indIEDest @recipient[:ie_indicator].to_s
        xml.IE Cnpj.digits(@recipient[:state_registration]) if @recipient[:ie_indicator].to_i == 1 && @recipient[:state_registration].present?
        xml.email @recipient[:email] if @recipient[:email].present?
      end
    end

    def line_totals
      @line_totals ||= @items.map { |item| (BigDecimal(item[:quantity].to_s) * BigDecimal(item[:unit_price].to_s)).round(2) }
    end

    def money(value)
      BigDecimal((value.presence || 0).to_s).round(2)
    end

    def discount_total
      @items.sum { |item| money(item[:discount]) }
    end

    def freight_total
      @items.sum { |item| money(item[:freight]) }
    end

    def note_total
      line_totals.sum - discount_total + freight_total
    end

    def build_det(xml, item, index)
      quantity = BigDecimal(item[:quantity].to_s)
      unit_price = BigDecimal(item[:unit_price].to_s)
      description = index.zero? && homologation? ? HOMOLOGATION_TEXT : item[:description]
      unit = item[:unit].presence || 'UN'

      xml.det(nItem: (index + 1).to_s) do
        xml.prod do
          xml.cProd item[:code]
          xml.cEAN 'SEM GTIN'
          xml.xProd description
          xml.NCM item[:ncm]
          xml.CEST item[:cest] if item[:cest].present?
          xml.CFOP item[:cfop]
          xml.uCom unit
          xml.qCom format('%.4f', quantity)
          xml.vUnCom format('%.4f', unit_price)
          xml.vProd format('%.2f', line_totals[index])
          xml.cEANTrib 'SEM GTIN'
          xml.uTrib unit
          xml.qTrib format('%.4f', quantity)
          xml.vUnTrib format('%.4f', unit_price)
          xml.vFrete format('%.2f', money(item[:freight])) if money(item[:freight]).positive?
          xml.vDesc format('%.2f', money(item[:discount])) if money(item[:discount]).positive?
          xml.indTot '1'
        end
        taxes = item_taxes[index]
        xml.imposto do
          build_icms(xml, item, taxes)
          build_pis_cofins(xml, 'PIS', @tax[:pis_cst], taxes[:pis])
          build_pis_cofins(xml, 'COFINS', @tax[:cofins_cst], taxes[:cofins])
          build_icms_uf_dest(xml, taxes[:difal]) if taxes[:difal]
          build_ibs_cbs(xml, taxes[:ibs_cbs]) if taxes[:ibs_cbs]
          xml.IBSCBS { xml.CST ibs_cbs_rule[:cst]; xml.cClassTrib ibs_cbs_rule[:class] } if ibs_cbs_exempt?
        end
      end
    end

    def build_icms(xml, item, taxes)
      origin = (item[:origin] || 0).to_s
      cst = @tax[:icms_situation]
      xml.ICMS do
        if icms_taxed?
          xml.ICMS00 do
            xml.orig origin
            xml.CST cst
            xml.modBC '3'
            xml.vBC format('%.2f', taxes[:icms_base])
            xml.pICMS format('%.4f', taxes[:icms_rate])
            xml.vICMS format('%.2f', taxes[:icms])
          end
        elsif normal_regime?
          xml.ICMS40 { xml.orig origin; xml.CST cst }
        else
          xml.ICMSSN102 { xml.orig origin; xml.CSOSN cst }
        end
      end
    end

    def build_pis_cofins(xml, tag, cst, tax)
      xml.send(tag) do
        if PIS_COFINS_TAXED.include?(cst)
          xml.send("#{tag}Aliq") do
            xml.CST cst
            xml.vBC format('%.2f', tax[:base])
            xml.send("p#{tag}", format('%.4f', tax[:rate]))
            xml.send("v#{tag}", format('%.2f', tax[:value]))
          end
        elsif PIS_COFINS_NOT_TAXED.include?(cst)
          xml.send("#{tag}NT") { xml.CST cst }
        else
          xml.send("#{tag}Outr") do
            xml.CST cst
            xml.vBC '0.00'
            xml.send("p#{tag}", '0.0000')
            xml.send("v#{tag}", '0.00')
          end
        end
      end
    end

    # DIFAL (EC 87/2015): a diferença entre o ICMS interno do destino e o interestadual vai para a UF do destinatário,
    # mais o FCP de lá. Cálculo em difal_tax.
    def build_icms_uf_dest(xml, difal)
      xml.ICMSUFDest do
        xml.vBCUFDest format('%.2f', difal[:base])
        xml.vBCFCPUFDest format('%.2f', difal[:base])
        xml.pFCPUFDest format('%.4f', difal[:fcp_rate])
        xml.pICMSUFDest format('%.4f', difal[:internal_rate])
        xml.pICMSInter format('%.2f', difal[:inter_rate])
        xml.pICMSInterPart '100.0000'
        xml.vFCPUFDest format('%.2f', difal[:fcp])
        xml.vICMSUFDest format('%.2f', difal[:dest])
        xml.vICMSUFRemet '0.00'
      end
    end

    def build_ibs_cbs(xml, tax)
      xml.IBSCBS do
        xml.CST ibs_cbs_rule[:cst]
        xml.cClassTrib ibs_cbs_rule[:class]
        xml.gIBSCBS do
          xml.vBC format('%.2f', tax[:base])
          xml.gIBSUF { xml.pIBSUF format('%.2f', ibs_cbs_rule[:ibs_uf]); xml.vIBSUF format('%.2f', tax[:ibs_uf]) }
          xml.gIBSMun { xml.pIBSMun format('%.2f', ibs_cbs_rule[:ibs_mun]); xml.vIBSMun format('%.2f', tax[:ibs_mun]) }
          xml.vIBS format('%.2f', tax[:ibs])
          xml.gCBS { xml.pCBS format('%.2f', ibs_cbs_rule[:cbs]); xml.vCBS format('%.2f', tax[:cbs]) }
        end
      end
    end

    def build_ibs_cbs_total(xml)
      zeros = ->(*tags) { tags.each { |tag| xml.send(tag, '0.00') } }
      xml.IBSCBSTot do
        xml.vBCIBSCBS format('%.2f', sum_tax { |t| t[:ibs_cbs][:base] })
        xml.gIBS do
          xml.gIBSUF { zeros.call(:vDif, :vDevTrib); xml.vIBSUF format('%.2f', sum_tax { |t| t[:ibs_cbs][:ibs_uf] }) }
          xml.gIBSMun { zeros.call(:vDif, :vDevTrib); xml.vIBSMun format('%.2f', sum_tax { |t| t[:ibs_cbs][:ibs_mun] }) }
          xml.vIBS format('%.2f', sum_tax { |t| t[:ibs_cbs][:ibs] })
          zeros.call(:vCredPres, :vCredPresCondSus)
        end
        xml.gCBS do
          zeros.call(:vDif, :vDevTrib)
          xml.vCBS format('%.2f', sum_tax { |t| t[:ibs_cbs][:cbs] })
          zeros.call(:vCredPres, :vCredPresCondSus)
        end
        xml.gMono { zeros.call(:vIBSMono, :vCBSMono, :vIBSMonoReten, :vCBSMonoReten, :vIBSMonoRet, :vCBSMonoRet) }
        xml.gEstornoCred { zeros.call(:vIBSEstCred, :vCBSEstCred) }
      end
    end

    def build_total(xml, total)
      xml.total do
        xml.ICMSTot do
          xml.vBC format('%.2f', sum_tax { |t| t[:icms_base] })
          xml.vICMS format('%.2f', sum_tax { |t| t[:icms] })
          xml.vICMSDeson '0.00'
          if difal?
            xml.vFCPUFDest format('%.2f', sum_tax { |t| t[:difal][:fcp] })
            xml.vICMSUFDest format('%.2f', sum_tax { |t| t[:difal][:dest] })
            xml.vICMSUFRemet '0.00'
          end
          %w[vFCP vBCST vST vFCPST vFCPSTRet].each { |tag| xml.send(tag, '0.00') }
          xml.vProd format('%.2f', line_totals.sum)
          xml.vFrete format('%.2f', freight_total)
          xml.vSeg '0.00'
          xml.vDesc format('%.2f', discount_total)
          %w[vII vIPI vIPIDevol].each { |tag| xml.send(tag, '0.00') }
          xml.vPIS format('%.2f', sum_tax { |t| t[:pis][:value] })
          xml.vCOFINS format('%.2f', sum_tax { |t| t[:cofins][:value] })
          xml.vOutro '0.00'
          xml.vNF format('%.2f', total)
        end
        if ibs_cbs?
          build_ibs_cbs_total(xml)
          xml.vNFTot format('%.2f', total)
        elsif ibs_cbs_exempt?
          xml.IBSCBSTot { xml.vBCIBSCBS '0.00' }
          xml.vNFTot format('%.2f', total)
        end
      end
    end

    def build_inf_adic(xml)
      return if @fisco_info.blank? && @additional_info.blank?

      xml.infAdic do
        xml.infAdFisco @fisco_info if @fisco_info.present?
        xml.infCpl @additional_info if @additional_info.present?
      end
    end

    # Fatura e duplicatas (parcelas do pedido). A soma das duplicatas é o líquido da fatura.
    def build_cobr(xml, total)
      return if @duplicates.empty?

      net = @duplicates.sum { |d| money(d[:value]) }
      xml.cobr do
        xml.fat do
          xml.nFat @number.to_s
          xml.vOrig format('%.2f', net)
          xml.vDesc format('%.2f', 0)
          xml.vLiq format('%.2f', net)
        end
        @duplicates.each do |dup|
          # dup_: "dup" sozinho é o Object#dup do Ruby, não a tag.
          xml.dup_ do
            xml.nDup format('%03d', dup[:number].to_i)
            xml.dVenc dup[:due].to_date.iso8601
            xml.vDup format('%.2f', money(dup[:value]))
          end
        end
      end
    end

    def build_pag(xml)
      xml.pag do
        @payments.each do |payment|
          xml.detPag do
            xml.indPag(payment[:installments].to_i > 1 ? '1' : '0') if payment[:method] != '90'
            xml.tPag payment[:method]
            xml.xPag payment[:description] if payment[:method] == '99'
            xml.vPag format('%.2f', money(payment[:amount]))
          end
        end
      end
    end

    # Responsável técnico: o Honey é software próprio, então é a própria empresa emissora.
    # Várias UFs rejeitam a nota sem este grupo (rejeição 972).
    def build_resp_tec(xml)
      phone = Cnpj.digits(@company.phone)
      return unless @company.email.present? && phone.length.between?(6, 14)

      xml.infRespTec do
        xml.CNPJ @company.cnpj
        xml.xContato @company.legal_name.to_s.first(60)
        xml.email @company.email
        xml.fone phone
      end
    end
  end
end
