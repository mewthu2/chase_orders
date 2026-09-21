module Nfe
  # Gera e assina a NF-e de um pedido B2B para uma empresa emissora.
  # Não transmite à SEFAZ: a nota fica "assinada".
  class Generator
    class Error < StandardError; end

    def self.call(order:, company:)
      new(order: order, company: company).call
    end

    def initialize(order:, company:)
      @order = order
      @company = company
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
    end

    def sale?
      @order.sale?
    end

    def operation_nature
      sale? ? @company.operation_nature_sale : @company.operation_nature_transfer
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
      same_state = recipient[:state] == @company.state
      if sale?
        same_state ? @company.cfop_sale_in_state : @company.cfop_sale_out_of_state
      else
        same_state ? @company.cfop_transfer_in_state : @company.cfop_transfer_out_of_state
      end
    end

    def build_items(recipient)
      order_items = @order.b2b_order_items.to_a
      products = Product.where(sku: order_items.map(&:sku)).index_by(&:sku)
      cfop = cfop_for(recipient)

      order_items.map do |order_item|
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
          unit_price: order_item.price - order_item.discount, cfop: cfop
        }
      end
    end

    def create_note(recipient, items)
      number = @company.next_nfe_number
      issued_at = Time.current
      result = XmlBuilder.new(
        company: @company, recipient: recipient, items: items, number: number, series: @company.nfe_series,
        operation_nature: operation_nature, issued_at: issued_at
      ).call
      signed_xml = Signer.new(@company.nfe_certificate).sign(result.xml)

      note = FiscalNote.create!(
        company: @company, b2b_order: @order, number: number, series: @company.nfe_series,
        access_key: result.access_key, environment: @company.environment, operation_nature: operation_nature,
        cfop_summary: items.map { |item| item[:cfop] }.uniq.join(', '), status: :assinada,
        total_value: result.total, issued_at: issued_at
      )
      note.xml.attach(io: StringIO.new(signed_xml), filename: "NFe#{result.access_key}.xml", content_type: 'application/xml')
      @company.update_column(:next_nfe_number, number + 1)
      note
    end
  end
end
