class Product < ApplicationRecord
  # Callbacks
  # Associacoes
  # Validacoes
  # Dados fiscais (NF-e): só validam quando preenchidos, para não afetar a sincronização.
  validates :ncm, format: { with: /\A\d{8}\z/, message: 'deve ter 8 dígitos' }, allow_blank: true
  validates :cest, format: { with: /\A\d{7}\z/, message: 'deve ter 7 dígitos' }, allow_blank: true
  validates :origin, inclusion: { in: 0..8 }
  validates :commercial_unit, presence: true

  # Escopos
  add_scope :search do |value|
    where('products.id LIKE :valor OR
           products.sku LIKE :valor OR
           products.shopify_inventory_item_id LIKE :valor OR
           products.cost LIKE :valor', valor: "#{value}%")
  end
  # Metodos estaticos
  # Metodos publicos

  # Contas Tiny onde o produto pode existir: [coluna do id, variável de ambiente do token].
  TINY_ACCOUNTS = [
    [:tiny_2_id, 'TOKEN_TINY2_PRODUCTION'],
    [:tiny_lagoa_seca_product_id, 'TOKEN_TINY_PRODUCTION'],
    [:tiny_bh_shopping_id, 'TOKEN_TINY_PRODUCTION_BH_SHOPPING'],
    [:tiny_rj_id, 'TOKEN_TINY_PRODUCTION_RJ']
  ].freeze
  # Quando nenhuma conta resolve, devolvemos o motivo mais informativo.
  TINY_IMPORT_REASON_PRIORITY = %i[invalid_ncm no_ncm_in_tiny not_found].freeze

  # Puxa os dados fiscais do produto no Tiny (somente leitura: nada é escrito no Tiny).
  # Tenta a conta B2B primeiro e, se ela não resolver, as demais contas onde o produto tem ID.
  # Só age em produto ainda sem NCM, para nunca sobrescrever o que já foi preenchido ou
  # corrigido no Honey. Devolve um símbolo: :updated, :already_filled, :no_tiny_id,
  # :not_found, :no_ncm_in_tiny, :invalid_ncm, :rate_limited, :invalid ou :error.
  def import_fiscal_data_from_tiny
    return :already_filled if ncm.present?

    accounts = tiny_accounts
    return :no_tiny_id if accounts.empty?

    reasons = []
    accounts.each do |tiny_id, token|
      result = import_fiscal_data_from_tiny_account(tiny_id, token)
      return result if %i[updated rate_limited invalid error].include?(result)

      reasons << result
    end

    TINY_IMPORT_REASON_PRIORITY.find { |reason| reasons.include?(reason) } || reasons.first
  rescue StandardError => e
    Rails.logger.error "Product#import_fiscal_data_from_tiny (#{sku}): #{e.class} #{e.message}"
    :error
  end

  # Tem ID em pelo menos uma conta Tiny (ou seja, dá para buscar os dados fiscais).
  def tiny_id?
    TINY_ACCOUNTS.any? { |attribute, _| self[attribute].present? }
  end

  def tiny_accounts
    TINY_ACCOUNTS.filter_map do |attribute, token_env|
      tiny_id = self[attribute].presence
      token = ENV[token_env].presence
      [tiny_id.to_s, token] if tiny_id && token
    end
  end

  def import_fiscal_data_from_tiny_account(tiny_id, token)
    retorno = Tiny::Products.find_product(tiny_id, token) || {}
    return :rate_limited if retorno[:codigo_erro].to_s == '6'

    tiny = retorno[:produto]
    return :not_found if tiny.blank?

    tiny_ncm = tiny[:ncm].to_s.gsub(/\D/, '')
    return :no_ncm_in_tiny if tiny_ncm.blank?
    return :invalid_ncm unless tiny_ncm.length == 8

    attrs = { ncm: tiny_ncm }
    tiny_cest = tiny[:cest].to_s.gsub(/\D/, '')
    attrs[:cest] = tiny_cest if tiny_cest.length == 7 && cest.blank?
    attrs[:origin] = tiny[:origem].to_i if tiny[:origem].to_s.match?(/\A[0-8]\z/)
    unit = tiny[:unidade].to_s.strip.upcase.first(6)
    attrs[:commercial_unit] = unit if unit.present?

    update(attrs) ? :updated : :invalid
  end
  private :tiny_accounts, :import_fiscal_data_from_tiny_account

  # Metodos GET
  # Metodos SET
end
