module Nfe
  # Gera e assina a NF-e de remessa de um lado da Colocação de estoque (Log02 ou Log03): a empresa configurada
  # remete ao depósito do Correios (destinatário da configuração) os itens do CSV daquele lado, pelo valor unitário
  # da nota de entrada. Sai como rascunho (Gerada, falta emitir): a transmissão é pelo botão Emitir na SEFAZ.
  # Com a conferência divergente (Log02 + Log03 diferente da entrada em algum SKU) só gera se a pessoa marcar
  # "estou ciente" (acknowledged_by): fica gravado no lado quem marcou e quando.
  class PlacementGenerator
    class Error < StandardError; end

    def self.call(**args) = new(**args).call

    def initialize(placement:, environment: nil, acknowledged_by: nil)
      @placement = placement
      @acknowledged_by = acknowledged_by
      @entry = placement.stock_entry
      @config = StockPlacementConfig.for(placement.side)
      @company = @config.company
      @nature = @config.operation_nature
      @environment = (environment.presence || @company&.environment).to_s
    end

    def call
      ensure_can_issue!
      recipient = build_recipient
      items = build_items(recipient)
      raise Error, "Dados fiscais ausentes: #{missing.uniq.to_sentence}." if missing.any?

      ActiveRecord::Base.transaction do
        note = @company.with_lock { create_note(recipient, items) }
        unless @entry.balanced?
          @placement.update!(divergence_acknowledged_by: @acknowledged_by, divergence_acknowledged_at: Time.current)
        end
        note
      end
    rescue XmlBuilder::Error, Signer::Error, Certificate::Error, ActiveRecord::RecordInvalid => e
      raise Error, e.message
    end

    private

    def missing = (@missing ||= [])

    def notes = @placement.fiscal_notes.where(company: @company, environment: @environment)

    def ensure_can_issue!
      raise Error, "Escolha a empresa e a natureza de operação do #{@placement.label} em Colocação de estoque → Configurações." unless @config.ready?
      if !@entry.balanced? && @acknowledged_by.nil?
        raise Error, 'A conferência com a nota de entrada não bate: acerte os CSVs ou marque que está ciente da divergência para gerar mesmo assim.'
      end
      raise Error, "A empresa #{@company.legal_name} não está ativa ou não tem certificado digital válido." unless @company.ready_to_issue?
      raise Error, 'Ambiente inválido.' unless FiscalNote.environments.key?(@environment)
      raise Error, @company.production_block_message if @environment == 'producao' && @company.homologacao?
      raise Error, "Já existe nota de remessa de #{@environment == 'homologacao' ? 'homologação' : 'produção'} ativa para o #{@placement.label}." if notes.active_statuses.exists?
      raise Error, 'A última nota deste lado ficou sem resposta da SEFAZ. Consulte-a antes de gerar outra.' if notes.erro.exists?
    end

    def build_recipient
      data = @config.recipient_data
      recipient = {
        name: data['name'], document: Cnpj.digits(data['document']), ie_indicator: data['state_registration'].present? ? 1 : 9,
        state_registration: data['state_registration'].presence, street: data['street'], number: data['number'].presence || 'S/N',
        complement: data['complement'].presence, neighbourhood: data['neighbourhood'], city: data['city'],
        city_ibge_code: data['city_ibge_code'].presence, state: data['state'].to_s.upcase, zip: Cnpj.digits(data['zip'])
      }
      recipient[:city_ibge_code] ||= Ibge.lookup(recipient[:zip]).to_h[:ibge].presence
      missing << 'nome do destinatário' if recipient[:name].blank?
      missing << 'CNPJ/CPF do destinatário' unless [11, 14].include?(recipient[:document].length)
      missing << 'endereço do destinatário' if recipient.values_at(:street, :neighbourhood, :city, :zip).any?(&:blank?)
      missing << 'código IBGE do destinatário' if recipient[:city_ibge_code].blank?
      missing << 'UF do destinatário' unless Company::STATES.key?(recipient[:state])
      recipient
    end

    def build_items(recipient)
      cfop = @nature.cfop_for(company_state: @company.state, recipient_state: recipient[:state], non_contributor: recipient[:ie_indicator] == 9)
      by_sku = @entry.items.group_by(&:sku)
      prices = @entry.unit_prices
      products = Product.where(sku: @placement.quantities.keys).index_by(&:sku)
      @placement.quantities.map do |sku, qty|
        line = by_sku[sku]&.first
        product = products[sku]
        ncm = line&.ncm.presence || product&.ncm
        missing << "NCM do SKU #{sku}" if ncm.blank?
        price = prices[sku].to_d
        missing << "valor do SKU #{sku} na nota de entrada" unless price.positive?
        { code: sku, description: line&.description.presence || product&.shopify_product_name.presence || sku,
          ncm: ncm, cest: line&.cest.presence || product&.cest, origin: line&.origin || product&.origin || 0,
          unit: product&.commercial_unit.presence || line&.unit.presence || 'UN', quantity: qty, unit_price: price.round(4), cfop: cfop }
      end
    end

    def note_context(recipient)
      { company_state: @company.state, recipient_state: recipient[:state], order_name: "Entrada NF-e #{@entry.number}",
        customer: recipient[:name] }
    end

    def additional_info(recipient)
      [@nature.notes_for(**note_context(recipient)).presence,
       "#{@placement.label} - Ref. NF-e de entrada nº #{@entry.number} de #{@entry.supplier_name} (chave #{@entry.access_key})"].compact.join(' | ')
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
        operation_nature: @nature.description, issued_at: issued_at, purpose: @nature.purpose, final_consumer: false,
        tax: @nature.tax_rules(company_state: @company.state, recipient_state: recipient[:state]),
        additional_info: additional_info(recipient), fisco_info: @nature.fisco_notes_for(**note_context(recipient)),
        environment: @environment, freight_mode: '9', ibs_cbs_exempt: XmlBuilder::IBS_CBS_TRANSFER
      ).call
      signed_xml = Signer.new(@company.nfe_certificate).sign(result.xml)

      note = reused || FiscalNote.new(company: @company, number: number, series: @company.nfe_series)
      note.assign_attributes(
        stock_placement: @placement, role: 'remessa', access_key: result.access_key, environment: @environment,
        payment_method: XmlBuilder::NO_PAYMENT.first[:method], operation_nature_id: @nature.id, operation_nature: @nature.description,
        cfop_summary: items.map { |i| i[:cfop] }.uniq.join(', '), status: :rascunho, total_value: result.total,
        issued_at: issued_at, protocol: nil, error_message: nil, sefaz_status_code: nil, sefaz_message: nil, sefaz_receipt: nil, authorized_at: nil
      )
      note.save!
      note.xml.attach(io: StringIO.new(signed_xml), filename: "NFe#{result.access_key}.xml", content_type: 'application/xml')
      @company.advance_nfe_number!(number, @environment) unless reused
      note
    end
  end
end
