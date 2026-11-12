module Nfe
  # Gera e assina a NF-e de um pedido B2B para uma empresa emissora, com a natureza de operação
  # escolhida (uma das vinculadas à empresa): dela vêm a descrição, o CFOP e a tributação.
  # Não transmite à SEFAZ: a nota fica "assinada".
  class Generator
    class Error < StandardError; end

    def self.call(order:, company:, nature:)
      new(order: order, company: company, nature: nature).call
    end

    def initialize(order:, company:, nature:)
      @order = order
      @company = company
      @nature = nature
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

    def ensure_can_issue!
      raise Error, 'A empresa não está ativa ou não tem certificado digital válido.' unless @company.ready_to_issue?
      raise Error, 'Já existe nota fiscal ativa para este pedido.' if FiscalNote.active_for?(@order)
      unless @nature&.active? && @company.available_natures.exists?(@nature.id)
        raise Error, 'Escolha uma natureza de operação ativa vinculada a esta empresa.'
      end
    end

    def sale?
      @order.sale?
    end

    def operation_nature
      @nature.description
    end

    def build_recipient
      source = sale? ? @order.client : @order.transfer_location
      if source.nil?
        missing << 'destinatário do pedido'
        return {}
      end

      recipient = sale? ? client_recipient(source) : location_recipient(source)
      missing << 'CNPJ/CPF do destinatário' unless [11, 14].include?(Cnpj.digits(recipient[:document]).length)
      missing << 'endereço do destinatário' if recipient.values_at(:street, :neighbourhood, :city, :zip).any?(&:blank?)
      missing << 'código IBGE do destinatário' if recipient[:city_ibge_code].blank?
      missing << 'UF do destinatário' unless Company::STATES.key?(recipient[:state])
      recipient
    end

    def client_recipient(client)
      {
        name: client.business_name.presence || client.responsible_name, document: client.registration,
        ie_indicator: client.ie_indicator, state_registration: client.state_registration,
        street: client.street, number: client.number.presence || 'S/N', neighbourhood: client.neighbourhood,
        city: client.city, city_ibge_code: client.city_ibge_code, state: client.state, zip: client.zip,
        phone: client.phone, email: client.email
      }
    end

    def location_recipient(location)
      {
        name: location.name, document: location.registration,
        ie_indicator: location.state_registration.present? ? 1 : 9, state_registration: location.state_registration,
        street: location.street, number: location.number.presence || 'S/N', complement: location.complement,
        neighbourhood: location.neighbourhood, city: location.city, city_ibge_code: location.city_ibge_code,
        state: location.state, zip: location.zip
      }
    end

    def cfop_for(recipient)
      @nature.cfop_for(company_state: @company.state, recipient_state: recipient[:state],
                       non_contributor: recipient[:ie_indicator].to_i == 9)
    end

    def build_items(recipient)
      order_items = @order.b2b_order_items.to_a
      products = Product.where(sku: order_items.map(&:sku)).index_by(&:sku)
      cfop = cfop_for(recipient)

      discounts = order_discount_shares(order_items)

      order_items.each_with_index.map do |order_item, index|
        product = products[order_item.sku]
        if product.nil?
          missing << "produto do SKU #{order_item.sku} não encontrado"
        elsif product.ncm.blank?
          missing << "NCM do SKU #{order_item.sku}"
        end

        {
          code: order_item.sku, description: product&.shopify_product_name.presence || order_item.name.presence || order_item.sku,
          ncm: product&.ncm, cest: product&.cest, origin: product&.origin || 0,
          unit: product&.commercial_unit.presence || 'UN', quantity: order_item.quantity,
          unit_price: order_item.price - order_item.discount, cfop: cfop, discount: discounts[index]
        }
      end
    end

    # Desconto livre do pedido (atacado) rateado pelos itens, proporcional ao valor de cada um (vDesc);
    # o último item fica com a sobra do arredondamento para a soma bater com o desconto do pedido.
    def order_discount_shares(order_items)
      total_discount = @order.respond_to?(:discount_amount) ? @order.discount_amount.to_d : 0.to_d
      return Array.new(order_items.size, 0) unless total_discount.positive?

      values = order_items.map { |i| (i.price.to_d - i.discount.to_d) * i.quantity.to_i }
      sum = values.sum
      return Array.new(order_items.size, 0) unless sum.positive?

      shares = values[0...-1].map { |v| (total_discount * v / sum).round(2) }
      shares << (total_discount - shares.sum)
    end

    def create_note(recipient, items)
      number = @company.current_nfe_number
      issued_at = Time.current
      result = XmlBuilder.new(
        company: @company, recipient: recipient, items: items, number: number, series: @company.nfe_series,
        operation_nature: operation_nature, issued_at: issued_at, purpose: @nature.purpose,
        final_consumer: @nature.final_consumer?,
        tax: @nature.tax_rules(company_state: @company.state, recipient_state: recipient[:state]),
        additional_info: @nature.notes_for(**note_context(recipient)),
        fisco_info: @nature.fisco_notes_for(**note_context(recipient))
      ).call
      signed_xml = Signer.new(@company.nfe_certificate).sign(result.xml)

      note = FiscalNote.create!(
        company: @company, b2b_order: @order, number: number, series: @company.nfe_series,
        access_key: result.access_key, environment: @company.environment, operation_nature: operation_nature,
        operation_nature_id: @nature.id,
        cfop_summary: items.map { |item| item[:cfop] }.uniq.join(', '), status: :assinada,
        total_value: result.total, issued_at: issued_at
      )
      note.xml.attach(io: StringIO.new(signed_xml), filename: "NFe#{result.access_key}.xml", content_type: 'application/xml')
      @company.advance_nfe_number!(number)
      note
    end

    def recipient_name
      source = sale? ? @order.client : @order.transfer_location
      sale? ? (source&.business_name.presence || source&.responsible_name) : source&.name
    end

    def note_context(recipient)
      { company_state: @company.state, recipient_state: recipient[:state], order_name: "Pedido #{@order.id}",
        customer: recipient_name }
    end
  end
end
