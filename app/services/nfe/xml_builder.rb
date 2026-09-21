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
    NORMAL_ICMS_CST = %w[40 41 50].freeze
    PIS_COFINS_NOT_TAXED = %w[04 05 06 07 08 09].freeze
    PIS_COFINS_OTHER = %w[49 99].freeze

    def self.access_key_check_digit(digits43)
      weights = [2, 3, 4, 5, 6, 7, 8, 9]
      sum = digits43.reverse.chars.each_with_index.sum { |char, index| char.to_i * weights[index % 8] }
      remainder = sum % 11
      remainder < 2 ? 0 : 11 - remainder
    end

    def initialize(company:, recipient:, items:, number:, series:, operation_nature:, issued_at:, cnf: nil)
      @company = company
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
      total = line_totals.sum

      builder = Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
        xml.NFe(xmlns: NAMESPACE) do
          xml.infNFe(Id: "NFe#{key}", versao: VERSION) do
            build_ide(xml, key)
            build_emit(xml)
            build_dest(xml)
            @items.each_with_index { |item, index| build_det(xml, item, index) }
            build_total(xml, total)
            xml.transp { xml.modFrete '9' }
            xml.pag { xml.detPag { xml.tPag '90'; xml.vPag '0.00' } }
          end
        end
      end

      Result.new(xml: builder.doc.root.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML),
                 access_key: key, total: total)
    end

    private

    def homologation?
      @company.homologacao?
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
    end

    def validate_tax_situations!
      icms = @company.icms_situation
      supported = @company.tax_regime == 3 ? NORMAL_ICMS_CST : SIMPLES_CSOSN
      raise Error, "Situação tributária de ICMS #{icms} não suportada para este regime." unless supported.include?(icms)

      [@company.pis_cst, @company.cofins_cst].each do |cst|
        next if (PIS_COFINS_NOT_TAXED + PIS_COFINS_OTHER).include?(cst)

        raise Error, "CST de PIS/COFINS #{cst} não suportado."
      end
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
        xml.finNFe '1'
        xml.indFinal '0'
        xml.indPres '0'
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
          xml.indTot '1'
        end
        xml.imposto do
          build_icms(xml, item)
          build_pis_cofins(xml, 'PIS', @company.pis_cst, 'pPIS', 'vPIS')
          build_pis_cofins(xml, 'COFINS', @company.cofins_cst, 'pCOFINS', 'vCOFINS')
        end
      end
    end

    def build_icms(xml, item)
      origin = (item[:origin] || 0).to_s
      xml.ICMS do
        if @company.tax_regime == 3
          xml.ICMS40 { xml.orig origin; xml.CST @company.icms_situation }
        else
          xml.ICMSSN102 { xml.orig origin; xml.CSOSN @company.icms_situation }
        end
      end
    end

    def build_pis_cofins(xml, tag, cst, rate_tag, value_tag)
      xml.send(tag) do
        if PIS_COFINS_NOT_TAXED.include?(cst)
          xml.send("#{tag}NT") { xml.CST cst }
        else
          xml.send("#{tag}Outr") do
            xml.CST cst
            xml.vBC '0.00'
            xml.send(rate_tag, '0.0000')
            xml.send(value_tag, '0.00')
          end
        end
      end
    end

    def build_total(xml, total)
      xml.total do
        xml.ICMSTot do
          %w[vBC vICMS vICMSDeson vFCP vBCST vST vFCPST vFCPSTRet].each { |tag| xml.send(tag, '0.00') }
          xml.vProd format('%.2f', total)
          %w[vFrete vSeg vDesc vII vIPI vIPIDevol vPIS vCOFINS vOutro].each { |tag| xml.send(tag, '0.00') }
          xml.vNF format('%.2f', total)
        end
      end
    end
  end
end
