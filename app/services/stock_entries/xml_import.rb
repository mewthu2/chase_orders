require 'nokogiri'

module StockEntries
  # Lê o XML de uma NF-e de compra (nfeProc ou só a NFe) e grava a StockEntry com os itens. Recusa XML que não é
  # NF-e, nota repetida (mesma chave) e nota que não é para um CNPJ da Chase cadastrado em Empresas.
  class XmlImport
    class Error < StandardError; end

    NS = { 'n' => 'http://www.portalfiscal.inf.br/nfe' }.freeze

    def self.call(io, user:) = new(io, user:).call

    def initialize(io, user:)
      @raw = io.respond_to?(:read) ? io.read : io.to_s
      @user = user
    end

    def call
      doc = Nokogiri::XML(@raw) { |c| c.strict.nonet }
      inf = doc.at_xpath('//n:infNFe', NS) or raise Error, 'O arquivo não é o XML de uma NF-e.'
      key = inf['Id'].to_s.delete_prefix('NFe')
      raise Error, 'O XML não tem a chave de acesso da nota.' unless key.match?(/\A\d{44}\z/)

      if (existing = StockEntry.find_by(access_key: key))
        raise Error, "Esta nota (nº #{existing.number} de #{existing.supplier_name}) já foi importada."
      end

      dest_cnpj = text(inf, 'n:dest/n:CNPJ')
      company = Company.all.detect { |c| Nfe::Cnpj.digits(c.cnpj) == dest_cnpj }
      raise Error, "A nota é para o CNPJ #{Nfe::Cnpj.format(dest_cnpj)}, que não é uma empresa da Chase cadastrada em Empresas." unless company

      items = inf.xpath('n:det', NS).map.with_index(1) { |det, i| item(det, i) }
      raise Error, 'A nota não tem itens.' if items.empty?

      status = doc.at_xpath('//n:protNFe/n:infProt/n:cStat', NS)&.text
      entry = StockEntry.new(
        company: company, access_key: key, number: text(inf, 'n:ide/n:nNF').to_i, series: text(inf, 'n:ide/n:serie').to_i,
        supplier_name: text(inf, 'n:emit/n:xNome'), supplier_cnpj: text(inf, 'n:emit/n:CNPJ').presence || text(inf, 'n:emit/n:CPF'),
        supplier_state: text(inf, 'n:emit/n:enderEmit/n:UF'), recipient_cnpj: dest_cnpj, nature_text: text(inf, 'n:ide/n:natOp'),
        issued_at: (Time.zone.parse(text(inf, 'n:ide/n:dhEmi')) rescue nil), total_value: decimal(text(inf, 'n:total/n:ICMSTot/n:vNF')),
        products_value: decimal(text(inf, 'n:total/n:ICMSTot/n:vProd')), authorized: %w[100 150].include?(status), created_by: @user
      )
      StockEntry.transaction do
        entry.save!
        items.each { |attrs| entry.items.create!(attrs) }
        entry.xml.attach(io: StringIO.new(@raw), filename: "NFe#{key}.xml", content_type: 'application/xml')
      end
      entry
    rescue Nokogiri::XML::SyntaxError
      raise Error, 'O arquivo não é um XML válido.'
    end

    private

    def item(det, position)
      prod = det.at_xpath('n:prod', NS)
      icms = det.at_xpath('n:imposto/n:ICMS/*', NS)
      ean = text(prod, 'n:cEAN')
      { position: position, sku: text(prod, 'n:cProd').upcase, ean: (ean unless ean.blank? || ean == 'SEM GTIN'),
        description: text(prod, 'n:xProd'), ncm: text(prod, 'n:NCM'), cest: text(prod, 'n:CEST').presence, cfop: text(prod, 'n:CFOP'),
        unit: text(prod, 'n:uCom'), quantity: decimal(text(prod, 'n:qCom')), unit_price: decimal(text(prod, 'n:vUnCom')),
        total: decimal(text(prod, 'n:vProd')), origin: icms && icms.at_xpath('n:orig', NS)&.text&.to_i }
    end

    def text(node, path) = node.at_xpath(path, NS)&.text.to_s.strip

    def decimal(value) = BigDecimal(value.presence || '0')
  end
end
