module Nfe
  # Gera e assina a NF-e de um pedido B2B para uma empresa emissora, com a natureza de operação
  # escolhida (uma das vinculadas à empresa): dela vêm a descrição, o CFOP e a tributação.
  # Não transmite à SEFAZ: a nota fica "assinada".
  class Generator
    class Error < StandardError; end

    def self.call(order:, company:, nature:, environment: nil, role: nil)
      new(order: order, company: company, nature: nature, environment: environment, role: role).call
    end

    # environment: homologação ou produção (sem ele, o ambiente atual da empresa). Cada pedido tem no máximo
    # uma nota ativa por ambiente, como as remessas da Transferência Interna.
    # role 'remessa': a nota de remessa do abastecimento (destinatário da remessa, sem transportadora), contada
    # à parte da nota do pedido.
    def initialize(order:, company:, nature:, environment: nil, role: nil)
      @order = order
      @role = role.presence
      raise ArgumentError, "papel inválido: #{@role}" if @role && !FiscalNote::ROLES.include?(@role)
      @company = company
      @nature = nature
      @environment = (environment.presence || company.environment).to_s
      raise ArgumentError, "ambiente inválido: #{@environment}" unless FiscalNote.environments.key?(@environment)
    end

    def call
      ensure_can_issue!
      recipient = build_recipient
      items = build_items(recipient)
      raise Error, "Dados fiscais ausentes: #{missing.to_sentence}." if missing.any?

      ActiveRecord::Base.transaction do
        # A checagem de nota ativa se repete dentro da trava: dois cliques (ou o clique e a rotina do Log02)
        # ao mesmo tempo geravam duas notas para o mesmo pedido.
        @company.with_lock do
          ensure_no_active_note!
          create_note(recipient, items)
        end
      end
    rescue XmlBuilder::Error, Signer::Error, Certificate::Error, ActiveRecord::RecordInvalid => e
      raise Error, e.message
    end

    private

    def missing
      @missing ||= []
    end

    def notes
      FiscalNote.where(b2b_order_id: @order.id, company: @company, environment: @environment, role: @role)
    end

    def remessa?
      @role == 'remessa'
    end

    def ensure_can_issue!
      raise Error, 'A empresa não está ativa ou não tem certificado digital válido.' unless @company.ready_to_issue?
      ensure_no_active_note!
      raise Error, 'A última nota deste pedido ficou sem resposta da SEFAZ. Consulte-a antes de emitir outra.' if notes.erro.exists?
      unless @nature&.active? && @company.available_natures.exists?(@nature.id)
        raise Error, 'Escolha uma natureza de operação ativa vinculada a esta empresa.'
      end
    end

    def ensure_no_active_note!
      return unless FiscalNote.active_statuses.where(b2b_order_id: @order.id, environment: @environment, role: @role).exists?

      env = @environment == 'homologacao' ? 'homologação' : 'produção'
      raise Error, "Já existe nota #{remessa? ? 'de remessa' : 'fiscal'} de #{env} ativa para este pedido."
    end

    def sale?
      @order.sale?
    end

    def operation_nature
      @nature.description
    end

    def build_recipient
      return build_remessa_recipient if remessa?

      source = sale? ? @order.client : (@order.b2c_transfer? ? :b2c : @order.transfer_location)
      if source.nil?
        missing << 'destinatário do pedido'
        return {}
      end

      recipient = if sale? then client_recipient(source)
                  elsif source == :b2c then b2c_recipient
                  else location_recipient(source)
                  end
      fill_ibge_from_zip(recipient, source)
      missing << 'CNPJ/CPF do destinatário' unless [11, 14].include?(Cnpj.digits(recipient[:document]).length)
      missing << 'endereço do destinatário' if recipient.values_at(:street, :neighbourhood, :city, :zip).any?(&:blank?)
      missing << 'código IBGE do destinatário' if recipient[:city_ibge_code].blank?
      missing << 'UF do destinatário' unless Company::STATES.key?(recipient[:state])
      recipient
    end

    # Remessa: o destinatário digitado (do pedido ou o padrão das configurações), com o IBGE pelo CEP se faltar.
    def build_remessa_recipient
      data = @order.remessa_recipient_data
      recipient = {
        name: data['name'], document: data['document'], ie_indicator: data['state_registration'].present? ? 1 : 9,
        state_registration: data['state_registration'].presence, street: data['street'], number: data['number'].presence || 'S/N',
        complement: data['complement'].presence, neighbourhood: data['neighbourhood'], city: data['city'],
        city_ibge_code: data['city_ibge_code'].presence, state: data['state'].upcase, zip: data['zip']
      }
      recipient[:city_ibge_code] ||= Ibge.lookup(recipient[:zip]).to_h[:ibge].presence
      missing << 'nome do destinatário da remessa' if recipient[:name].blank?
      missing << 'CNPJ/CPF do destinatário da remessa' unless [11, 14].include?(Cnpj.digits(recipient[:document]).length)
      missing << 'endereço do destinatário da remessa' if recipient.values_at(:street, :neighbourhood, :city, :zip).any?(&:blank?)
      missing << 'código IBGE do destinatário da remessa' if recipient[:city_ibge_code].blank?
      missing << 'UF do destinatário da remessa' unless Company::STATES.key?(recipient[:state])
      recipient
    end

    # Cadastro sem o código IBGE (comum nas lojas de abastecimento): busca pelo CEP e grava no cadastro,
    # para a próxima nota já sair com ele.
    def fill_ibge_from_zip(recipient, source)
      return if recipient[:city_ibge_code].present?

      ibge = Ibge.lookup(recipient[:zip]).to_h[:ibge]
      return if ibge.blank?

      recipient[:city_ibge_code] = ibge
      source.update_columns(city_ibge_code: ibge, updated_at: Time.current) if source.respond_to?(:city_ibge_code) && source.persisted?
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

    # Transferência B2B -> B2C: destinatário fixo, a filial da loja online.
    def b2c_recipient
      r = B2bTinyService::B2C_TRANSFER_RECIPIENT
      {
        name: r[:nome], document: r[:cpf_cnpj], ie_indicator: r[:ie].present? ? 1 : 9, state_registration: r[:ie],
        street: r[:endereco], number: r[:numero], complement: r[:complemento], neighbourhood: r[:bairro],
        city: r[:cidade], city_ibge_code: HoneyB2bLog::B2C_RECIPIENT_IBGE, state: r[:uf], zip: r[:cep]
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
      freights = shares_of(order_items, @order.freight_value.to_d)

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
          unit_price: order_item.price - order_item.discount, cfop: cfop, discount: discounts[index], freight: freights[index]
        }
      end
    end

    # Desconto livre do pedido (atacado) rateado pelos itens, proporcional ao valor de cada um (vDesc);
    # o último item fica com a sobra do arredondamento para a soma bater com o desconto do pedido.
    def order_discount_shares(order_items)
      shares_of(order_items, @order.respond_to?(:discount_amount) ? @order.discount_amount.to_d : 0.to_d)
    end

    # Rateia um valor do pedido (desconto ou frete) pelos itens, proporcional ao valor de cada um.
    def shares_of(order_items, amount)
      return Array.new(order_items.size, 0) unless amount.positive?

      values = order_items.map { |i| (i.price.to_d - i.discount.to_d) * i.quantity.to_i }
      sum = values.sum
      return Array.new(order_items.size, 0) unless sum.positive?

      shares = values[0...-1].map { |v| (amount * v / sum).round(2) }
      shares << (amount - shares.sum)
    end

    # Forma de pagamento do atacado (tPag): boleto 15, cartão 03 (crédito), PIX 17. Transferência: sem pagamento.
    PAYMENT_CODES = { 'boleto' => '15', 'cartao' => '03', 'pix' => '17' }.freeze

    def payments
      code = PAYMENT_CODES[@order.payment_method]
      return nil unless sale? && code

      [{ method: code, amount: @order.grand_total, installments: @order.installment_days.size }]
    end

    def duplicates
      return nil unless sale?

      @order.installments.map { |p| { number: p[:number], due: p[:date], value: p[:value] } }
    end

    # Rejeitada (não denegada) devolve o número: a nova nota usa o mesmo, sem pular a numeração.
    def reusable_note
      notes.rejeitada.where.not(sefaz_status_code: Transmitter::DENIED_CODES).order(:created_at).last
    end

    def create_note(recipient, items)
      reused = reusable_note
      number = reused&.number || @company.current_nfe_number(@environment)
      issued_at = Time.current
      result = XmlBuilder.new(
        company: @company, recipient: recipient, items: items, number: number, series: @company.nfe_series,
        operation_nature: operation_nature, issued_at: issued_at, purpose: @nature.purpose,
        final_consumer: @nature.final_consumer?,
        tax: @nature.tax_rules(company_state: @company.state, recipient_state: recipient[:state]),
        additional_info: (@order.nf_additional_info.presence unless remessa?) || @nature.notes_for(**note_context(recipient)),
        fisco_info: @nature.fisco_notes_for(**note_context(recipient)), environment: @environment,
        freight_mode: freight_mode, carrier: carrier_data, payments: payments, duplicates: duplicates,
        # Transferência (abastecimento e B2C) leva o IBS/CBS de não incidência, como a Transferência Interna:
        # sem o grupo, a SEFAZ rejeita (1115 "IBS/CBS não informado").
        ibs_cbs_exempt: (XmlBuilder::IBS_CBS_TRANSFER unless sale?)
      ).call
      signed_xml = Signer.new(@company.nfe_certificate).sign(result.xml)

      note = reused || FiscalNote.new(company: @company, number: number, series: @company.nfe_series)
      note.assign_attributes(
        b2b_order: @order, role: @role, access_key: result.access_key, environment: @environment, operation_nature: operation_nature,
        operation_nature_id: @nature.id, cfop_summary: items.map { |item| item[:cfop] }.uniq.join(', '), status: :assinada,
        total_value: result.total, issued_at: issued_at, protocol: nil, error_message: nil, sefaz_status_code: nil,
        sefaz_message: nil, sefaz_receipt: nil, authorized_at: nil
      )
      note.save!
      note.xml.attach(io: StringIO.new(signed_xml), filename: "NFe#{result.access_key}.xml", content_type: 'application/xml')
      @company.advance_nfe_number!(number, @environment) unless reused
      note
    end

    def recipient_name
      return @order.remessa_recipient_data['name'] if remessa?
      return B2bTinyService::B2C_TRANSFER_RECIPIENT[:nome] if @order.b2c_transfer?

      source = sale? ? @order.client : @order.transfer_location
      sale? ? (source&.business_name.presence || source&.responsible_name) : source&.name
    end

    # Transportadora da nota: a escolhida na aba Nota fiscal ou, sem ela, a do pedido (abastecimento por transportadora).
    def note_carrier
      return nil if remessa?

      @order.nf_carrier || @order.carrier
    end

    # Modalidade do frete: a escolhida na aba Nota fiscal; sem ela, por conta do remetente quando há frete ou
    # transportadora, e sem frete no resto.
    def freight_mode
      return '9' if remessa? # remessa para o depósito: sem ocorrência de transporte, como na NF-e 15777
      return @order.nf_freight_mode if @order.nf_freight_mode.present?

      @order.freight_value.to_d.positive? || note_carrier ? '0' : '9'
    end

    def carrier_data
      carrier = note_carrier
      return nil unless carrier

      address = [carrier.street, carrier.number, carrier.complement.presence].compact.join(', ')
      { document: carrier.registration, name: carrier.name, state_registration: carrier.state_registration,
        address: address, city: carrier.city, state: carrier.state }
    end

    def note_context(recipient)
      { company_state: @company.state, recipient_state: recipient[:state], order_name: "Pedido #{@order.id}",
        customer: recipient_name }
    end
  end
end
