module Nfe
  # Gera e assina a NF-e de transferência de uma remessa da Transferência Interna: a empresa da loja de
  # origem emite para a empresa da loja de destino. A transmissão é do Nfe::Transmitter.
  # Usa a natureza de transferência vinculada à empresa (a marcada como padrão, se houver mais de uma):
  # dela vêm a descrição, o CFOP e a tributação.
  # Se a última nota da remessa foi rejeitada pela SEFAZ, reaproveita o número dela.
  # environment: homologação ou produção (sem ele, o ambiente atual da empresa). Cada remessa tem no
  # máximo uma nota ativa por ambiente, cada uma com a numeração do seu ambiente.
  class TransferGenerator
    class Error < StandardError; end

    def self.call(**args)
      new(**args).call
    end

    def initialize(shipment:, company:, recipient_company:, environment: nil)
      @shipment = shipment
      @environment = (environment.presence || company.environment).to_s
      raise ArgumentError, "ambiente inválido: #{@environment}" unless FiscalNote.environments.key?(@environment)

      @transfer = shipment.internal_transfer
      @company = company
      @recipient_company = recipient_company
      @nature = OperationNature.default_for(company, :transfer)
    end

    def call
      ensure_can_issue!
      recipient = build_recipient
      items = build_items(recipient)
      raise Error, "Dados fiscais ausentes: #{missing.to_sentence}." if missing.any?

      ActiveRecord::Base.transaction do
        @company.with_lock { create_note(recipient, items) }
      end
    rescue XmlBuilder::Error, Signer::Error, Certificate::Error, ActiveRecord::RecordInvalid => e
      raise Error, e.message
    end

    private

    def missing
      @missing ||= []
    end

    def notes
      @shipment.fiscal_notes.where(company: @company, environment: @environment)
    end

    def ensure_can_issue!
      raise Error, "A empresa #{@company.legal_name} não está ativa ou não tem certificado digital válido." unless @company.ready_to_issue?
      raise Error, "Vincule uma natureza de operação de transferência à empresa #{@company.legal_name} (Empresas → Naturezas de operação)." unless @nature
      raise Error, "Já existe nota fiscal de #{environment_label} ativa para esta remessa." if notes.active_statuses.exists?
      raise Error, 'A última nota desta remessa ficou sem resposta da SEFAZ. Consulte-a antes de emitir outra.' if notes.erro.exists?
    end

    def environment_label
      @environment == 'homologacao' ? 'homologação' : 'produção'
    end

    def build_recipient
      c = @recipient_company
      recipient = {
        name: c.legal_name, document: Cnpj.digits(c.cnpj), ie_indicator: c.state_registration.present? ? 1 : 9,
        state_registration: c.state_registration, street: c.street, number: c.number.presence || 'S/N',
        complement: c.complement, neighbourhood: c.neighbourhood, city: c.city, city_ibge_code: c.city_ibge_code,
        state: c.state, zip: Cnpj.digits(c.zip), phone: c.phone, email: c.email
      }
      missing << "endereço da empresa #{c.legal_name}" if recipient.values_at(:street, :neighbourhood, :city).any?(&:blank?)
      missing << "código IBGE do município da empresa #{c.legal_name}" unless recipient[:city_ibge_code].to_s.match?(/\A\d{7}\z/)
      recipient
    end

    def cfop(recipient)
      @nature.cfop_for(company_state: @company.state, recipient_state: recipient[:state])
    end

    # Valor do item na transferência: 80% do preço de venda do produto (sem preço, o custo).
    def build_items(recipient)
      lines = @shipment.items.includes(:product).reject { |item| item.cancelled? || item.failed? }
      missing << 'itens na remessa' if lines.empty?
      code = cfop(recipient)

      lines.map do |line|
        product = line.product
        missing << "NCM do SKU #{product.sku}" if product.ncm.blank?
        price = unit_price(product)
        missing << "preço ou custo do SKU #{product.sku}" unless price.positive?

        {
          code: product.sku, description: product.shopify_product_name.presence || product.sku,
          ncm: product.ncm, cest: product.cest, origin: product.origin || 0,
          unit: product.commercial_unit.presence || 'UN', quantity: line.quantity, unit_price: price, cfop: code
        }
      end
    end

    PRICE_SHARE = BigDecimal('0.8')

    def unit_price(product)
      price = decimal(product.price)
      return (price * PRICE_SHARE).round(2) if price.positive?

      decimal(product.cost).round(2)
    end

    def decimal(value)
      BigDecimal(value.to_s.tr(',', '.').presence || '0')
    rescue ArgumentError
      BigDecimal('0')
    end

    def operation_nature
      @nature.description
    end

    def additional_info
      origin = "#{@shipment.origin_location.name} (CNPJ #{Cnpj.format(@company.cnpj)}, #{@company.city}/#{@company.state})"
      destination = "#{@transfer.destination_location.name} (CNPJ #{Cnpj.format(@recipient_company.cnpj)}, " \
                    "#{@recipient_company.city}/#{@recipient_company.state})"
      [@nature&.notes_for(**note_context),
       "Transferência interna nº #{@transfer.id} - ORIGEM: #{origin} -> DESTINO: #{destination}"].compact.join(' | ')
    end

    def note_context
      { company_state: @company.state, recipient_state: @recipient_company.state,
        order_name: "Transferência #{@transfer.id}", customer: @recipient_company.legal_name }
    end

    def reusable_note
      notes.rejeitada.where.not(sefaz_status_code: Transmitter::DENIED_CODES).order(:created_at).last
    end

    def create_note(recipient, items)
      reused = reusable_note
      number = reused&.number || @company.current_nfe_number(@environment)
      issued_at = Time.current
      result = XmlBuilder.new(
        company: @company, recipient: recipient, items: items, number: number, series: @company.nfe_series,
        operation_nature: operation_nature, issued_at: issued_at, purpose: @nature&.purpose || 1, final_consumer: false,
        tax: @nature&.tax_rules(company_state: @company.state, recipient_state: recipient[:state]),
        additional_info: additional_info, ibs_cbs_exempt: XmlBuilder::IBS_CBS_TRANSFER,
        fisco_info: @nature&.fisco_notes_for(**note_context), environment: @environment
      ).call
      signed_xml = Signer.new(@company.nfe_certificate).sign(result.xml)

      note = reused || FiscalNote.new(company: @company, number: number, series: @company.nfe_series)
      note.assign_attributes(
        internal_transfer_shipment: @shipment, access_key: result.access_key, environment: @environment,
        operation_nature_id: @nature&.id, operation_nature: operation_nature,
        cfop_summary: items.map { |i| i[:cfop] }.uniq.join(', '), status: :assinada, total_value: result.total,
        issued_at: issued_at, protocol: nil, error_message: nil, sefaz_status_code: nil, sefaz_message: nil,
        sefaz_receipt: nil, authorized_at: nil
      )
      note.save!
      note.xml.attach(io: StringIO.new(signed_xml), filename: "NFe#{result.access_key}.xml", content_type: 'application/xml')
      @company.advance_nfe_number!(number, @environment) unless reused
      note
    end
  end
end
