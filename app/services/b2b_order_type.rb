# Tipo dos pedidos da conta Tiny B2B (Tiny2) mostrado nas telas do Correios B2B: abastecimento das lojas,
# transferência B2B -> B2C ou B2B comum (atacado). O Tiny não guarda o tipo, então ele é deduzido, nessa ordem:
#   1. pedido criado no Honey (B2bOrder com o tiny_reference_id) — o kind dele;
#   2. dados enviados aos Correios (params da criação): CNPJ do destinatário e mão própria;
#   3. pedido completo do Tiny (observações e CNPJ do cliente), buscado só quando o destinatário é a própria
#      Chase (lojas e filial B2C têm o mesmo nome) e guardado em cache;
#   4. o resto é B2B comum.
module B2bOrderType
  module_function

  LABELS = {
    store_supply: 'Abastecimento Loja',
    b2c_transfer: 'Transferência B2B → B2C',
    sale: 'B2B Comum'
  }.freeze

  KIND_TYPES = { 'sale' => :sale, 'stock_transfer' => :store_supply, 'b2c_transfer' => :b2c_transfer }.freeze

  # Limite de pedidos buscados no Tiny por tela, para não travar o carregamento.
  MAX_TINY_LOOKUPS = 15
  CACHE_TTL = 30.days

  # tiny_order_ids => { 'id' => :tipo }. names: { 'id' => nome do cliente } (da listagem do Tiny), para decidir
  # quando vale buscar o pedido completo.
  def for_orders(tiny_order_ids, names: {})
    ids = Array(tiny_order_ids).map(&:to_s).reject(&:blank?).uniq
    return {} if ids.empty?

    # Abastecimento antigo guarda o número da nota (não o id do pedido) e não entra aqui.
    types = B2bOrder.where(tiny_reference_id: ids).select(&:tiny_order?)
                    .to_h { |order| [order.tiny_reference_id.to_s, KIND_TYPES[order.kind]] }

    stores = store_cnpjs
    store_names = TransferLocation.pluck(:name).map { |name| name.to_s.downcase.strip }

    from_attempts(ids - types.keys, stores:).each { |id, type| types[id] ||= type }

    lookups = 0
    (ids - types.keys).each do |id|
      next unless chase_recipient?(names[id.to_s] || names[id.to_i], store_names)

      cached = Rails.cache.read(cache_key(id))
      if cached
        types[id] = cached.to_sym
      elsif lookups < MAX_TINY_LOOKUPS
        lookups += 1
        type = from_tiny(id, stores:)
        if type
          Rails.cache.write(cache_key(id), type.to_s, expires_in: CACHE_TTL)
          types[id] = type
        end
      end
    end

    ids.each { |id| types[id] ||= :sale }
    types
  end

  def label(type)
    LABELS[type&.to_sym]
  end

  # cnpj: CNPJ do destinatário; notes: observações do pedido.
  def classify(cnpj:, notes: '', hand_delivery: false, stores: store_cnpjs)
    digits = cnpj.to_s.gsub(/\D/, '')
    text = notes.to_s.downcase

    return :b2c_transfer if text.include?(B2bTinyService::B2C_TRANSFER_TAG.downcase) || digits == b2c_cnpj
    return :store_supply if hand_delivery || text.include?(B2bTinyService::HAND_DELIVERY_TAG.downcase) ||
                            stores.include?(digits)

    :sale
  end

  def from_attempts(ids, stores: store_cnpjs)
    return {} if ids.empty?

    Attempt.where(kinds: :create_correios_order_tiny2, tiny_order_id: ids).where.not(params: [nil, ''])
           .order(:id).pluck(:tiny_order_id, :params)
           .to_h { |id, params| [id.to_s, from_params(params, stores:)] }
  end

  # params é o Hash#inspect dos dados enviados aos Correios.
  def from_params(params, stores: store_cnpjs)
    text = params.to_s
    cnpj = text[/(?::cpf_cnpj=>|\bcpf_cnpj: )"([^"]*)"/, 1]
    hand_delivery = text.match?(/(?::mao_propria=>|\bmao_propria: )true/)
    classify(cnpj:, hand_delivery:, stores:)
  end

  def from_tiny(id, stores: store_cnpjs)
    pedido = Tiny::Orders.obtain_order(ENV.fetch('TOKEN_TINY2_PRODUCTION'), id)&.dig(:pedido)
    return if pedido.blank?

    notes = [pedido[:obs], pedido[:obs_interna], Array(pedido[:marcadores]).map { |m| m.dig(:marcador, :descricao) }].flatten.compact.join(' ')
    classify(cnpj: pedido.dig(:cliente, :cpf_cnpj), notes:, stores:)
  rescue StandardError => e
    Rails.logger.warn "B2bOrderType.from_tiny(#{id}): #{e.message}"
    nil
  end

  # Lojas e filial B2C saem como "CHASE BRASIL ..." (ou com o nome cadastrado da loja).
  def chase_recipient?(name, store_names)
    text = name.to_s.downcase.strip
    return false if text.empty?

    text.include?('chase') || store_names.include?(text)
  end

  def b2c_cnpj
    B2bTinyService::B2C_TRANSFER_RECIPIENT[:cpf_cnpj].gsub(/\D/, '')
  end

  def store_cnpjs
    TransferLocation.pluck(:registration).map { |cnpj| cnpj.to_s.gsub(/\D/, '') }
  end

  def cache_key(id)
    "b2b_order_type/#{id}"
  end
end
