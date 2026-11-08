module Nfe
  # Gera e assina a NF-e de venda ao consumidor final de um pedido da Shopify. A transmissão é do Nfe::Transmitter.
  # Se a última nota do pedido foi rejeitada pela SEFAZ, reaproveita o número dela (nota rejeitada não usa número).
  class ShopifyGenerator
    class Error < StandardError; end

    RECIPIENT_FIELDS = %i[name document ie_indicator state_registration street number complement neighbourhood city
                          city_ibge_code state zip phone email].freeze

    # recipient: o destinatário conferido na tela; payment: { method:, installments:, description: }.
    def self.call(**args)
      new(**args).call
    end

    def initialize(company:, nature:, shopify_order:, recipient:, payment:, freight_mode: '0')
      @company = company
      @nature = nature
      @shopify_order = shopify_order
      @recipient = normalize(recipient)
      @payment = payment
      @freight_mode = freight_mode
    end

    def call
      ensure_can_issue!
      items = build_items
      validate_recipient!
      raise Error, "Dados fiscais ausentes: #{missing.to_sentence}." if missing.any?

      ActiveRecord::Base.transaction do
        @company.with_lock { create_note(items) }
      end
    rescue XmlBuilder::Error, Signer::Error, Certificate::Error, ActiveRecord::RecordInvalid => e
      raise Error, e.message
    end

    private

    def missing
      @missing ||= []
    end

    # Só as notas do ambiente atual: um teste em homologação não impede a nota real do pedido.
    def notes_for_order
      FiscalNote.where(shopify_order_name: @shopify_order.name, environment: @company.environment)
    end

    def ensure_can_issue!
      raise Error, 'A empresa não está ativa ou não tem certificado digital válido.' unless @company.ready_to_issue?
      raise Error, 'Escolha uma natureza de operação ativa vinculada a esta empresa.' unless @nature&.active? && @company.available_natures.exists?(@nature.id)
      raise Error, @shopify_order.blocking_issues.to_sentence if @shopify_order.blocking_issues.any?
      raise Error, 'Já existe nota fiscal ativa para este pedido.' if notes_for_order.active_statuses.exists?
      return unless notes_for_order.erro.exists?

      raise Error, 'A última nota deste pedido ficou sem resposta da SEFAZ. Consulte-a antes de emitir outra.'
    end

    def normalize(recipient)
      data = recipient.to_h.symbolize_keys.slice(*RECIPIENT_FIELDS)
      data.transform_values! { |v| v.is_a?(String) ? v.strip : v }
      data[:document] = Cnpj.digits(data[:document])
      data[:zip] = Cnpj.digits(data[:zip])
      data[:state] = data[:state].to_s.upcase
      data[:number] = data[:number].presence || 'S/N'
      data[:ie_indicator] = (data[:ie_indicator].presence || 9).to_i
      data
    end

    def validate_recipient!
      r = @recipient
      missing << 'nome do destinatário' if r[:name].blank?
      missing << 'CPF/CNPJ válido do destinatário' unless Cnpj.valid_document?(r[:document])
      missing << 'endereço do destinatário' if r.values_at(:street, :neighbourhood, :city).any?(&:blank?)
      missing << 'CEP do destinatário' unless r[:zip].to_s.length == 8
      missing << 'código IBGE do município do destinatário' unless r[:city_ibge_code].to_s.match?(/\A\d{7}\z/)
      missing << 'UF do destinatário' unless Company::STATES.key?(r[:state])
      missing << 'IE do destinatário' if r[:ie_indicator] == 1 && r[:state_registration].blank?
    end

    def cfop
      @nature.cfop_for(company_state: @company.state, recipient_state: @recipient[:state],
                       non_contributor: @recipient[:ie_indicator] == 9)
    end

    def build_items
      lines = @shopify_order.items
      products = Product.where(sku: lines.map { |l| l[:sku] }).index_by(&:sku)
      freights = split_freight(lines)

      lines.each_with_index.map do |line, index|
        product = products[line[:sku]]
        if line[:sku].blank?
          missing << "SKU do item \"#{line[:name]}\""
        elsif product.nil?
          missing << "produto do SKU #{line[:sku]} não encontrado"
        elsif product.ncm.blank?
          missing << "NCM do SKU #{line[:sku]}"
        end

        {
          code: line[:sku].presence || "ITEM#{index + 1}",
          description: product&.shopify_product_name.presence || line[:name],
          ncm: product&.ncm, cest: product&.cest, origin: product&.origin || 0,
          unit: product&.commercial_unit.presence || 'UN', quantity: line[:quantity],
          unit_price: line[:unit_price], discount: line[:discount], freight: freights[index], cfop: cfop
        }
      end
    end

    # O frete da nota é informado por item; rateia pelo valor líquido e joga a sobra do arredondamento no último.
    def split_freight(lines)
      total = @shopify_order.freight
      nets = lines.map { |l| l[:unit_price] * l[:quantity] - l[:discount] }
      base = nets.sum
      return Array.new(lines.size, BigDecimal('0')) if total.zero? || base <= 0

      shares = nets[0...-1].map { |net| (total * net / base).round(2) }
      shares << (total - shares.sum)
    end

    def reusable_note
      notes_for_order.rejeitada.where(company: @company, environment: @company.environment)
                     .where.not(sefaz_status_code: Transmitter::DENIED_CODES).order(:created_at).last
    end

    def create_note(items)
      reused = reusable_note
      number = reused&.number || @company.current_nfe_number
      issued_at = Time.current
      result = XmlBuilder.new(
        company: @company, recipient: @recipient, items: items, number: number, series: @company.nfe_series,
        operation_nature: @nature.description, issued_at: issued_at, purpose: @nature.purpose,
        final_consumer: @nature.final_consumer?, presence: '2', freight_mode: @freight_mode,
        tax: @nature.tax_rules(company_state: @company.state, recipient_state: @recipient[:state]),
        payments: [@payment.to_h.symbolize_keys.merge(amount: total_for(items))],
        additional_info: additional_info,
        fisco_info: @nature.fisco_notes_for(**note_context)
      ).call
      signed_xml = Signer.new(@company.nfe_certificate).sign(result.xml)

      note = reused || FiscalNote.new(company: @company, number: number, series: @company.nfe_series)
      note.assign_attributes(
        order: @shopify_order.local_order, shopify_order_name: @shopify_order.name,
        access_key: result.access_key, environment: @company.environment, operation_nature_id: @nature.id,
        operation_nature: @nature.description, cfop_summary: items.map { |i| i[:cfop] }.uniq.join(', '),
        status: :assinada, total_value: result.total, issued_at: issued_at, protocol: nil, error_message: nil,
        sefaz_status_code: nil, sefaz_message: nil, sefaz_receipt: nil, authorized_at: nil
      )
      note.save!
      note.xml.attach(io: StringIO.new(signed_xml), filename: "NFe#{result.access_key}.xml", content_type: 'application/xml')
      @company.advance_nfe_number!(number) unless reused
      note
    end

    def additional_info
      [@nature.notes_for(**note_context), "Pedido #{@shopify_order.name} (loja virtual)"].compact.join(' | ')
    end

    def note_context
      { company_state: @company.state, recipient_state: @recipient[:state], order_name: @shopify_order.name,
        customer: @recipient[:name] }
    end

    def total_for(items)
      items.sum do |i|
        (BigDecimal(i[:quantity].to_s) * BigDecimal(i[:unit_price].to_s)).round(2) - i[:discount].to_d + i[:freight].to_d
      end
    end
  end
end
