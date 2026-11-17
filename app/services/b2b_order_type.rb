# Tipo dos pedidos da conta Tiny B2B (Tiny2) mostrado nas telas do Correios B2B: abastecimento das lojas,
# transferência B2B -> B2C ou B2B comum (atacado). O Tiny não guarda o tipo, então ele é deduzido, nessa ordem:
#   1. pedido criado no Honey (B2bOrder com o tiny_reference_id) — o kind dele;
#   2. dados enviados aos Correios (params da criação): CNPJ do destinatário e mão própria;
#   3. tipo guardado em cache de consultas antigas ao Tiny (o Tiny 2 não é mais consultado);
#   4. o resto é B2B comum.
module B2bOrderType
  module_function

  LABELS = {
    store_supply: 'Abastecimento Loja',
    b2c_transfer: 'Transferência B2B → B2C',
    sale: 'B2B Comum'
  }.freeze

  KIND_TYPES = { 'sale' => :sale, 'stock_transfer' => :store_supply, 'b2c_transfer' => :b2c_transfer }.freeze

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

    from_attempts(ids - types.keys, stores:).each { |id, type| types[id] ||= type }

    # O Tiny 2 não é mais usado: só vale o tipo já guardado de consultas antigas.
    (ids - types.keys).each do |id|
      cached = Rails.cache.read(cache_key(id))
      types[id] = cached.to_sym if cached
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
