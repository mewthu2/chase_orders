# Configuração do atacado (uma linha só):
# - fixed_freight_value: antigo frete fixo, substituído pela Tabela de frete (B2bFreightRate);
# - seamless_discount_percent / default_discount_percent: desconto sobre o preço de varejo que dá o preço
#   sugerido do item no pedido do atacado (Seamless = produto com "Seamless" no nome; o resto usa o padrão);
# - issuer_company / sale_nature: quem emite a NF-e dos pedidos de atacado do Log02 feitos no Honey e com
#   que natureza;
# - supply_issuer_company / supply_nature e b2c_issuer_company / b2c_nature: o mesmo para o abastecimento das
#   lojas e para a transferência B2C (nas Configurações de cada tela). Sem escolha, valem a empresa do atacado
#   e transfer_nature (a natureza de transferência de antes, comum aos dois);
# - b2c_to_b2b_*: transferência no sentido B2C → B2B, que não vai ao Correios: a filial B2C emite a nota de
#   transferência para a filial B2B, e a filial B2B emite a nota de remessa;
# - b2b_to_b2c_remessa_*: nota de remessa do sentido B2B → B2C: a filial B2C, que recebe a transferência,
#   manda para o depósito do Correios.
class B2bSetting < ApplicationRecord
  DEFAULT_ISSUER_CNPJ = '25405327000255'.freeze
  DEFAULT_SALE_NATURE = 'Atacado'.freeze
  DEFAULT_TRANSFER_NATURE = 'Transferência entre Filiais'.freeze

  belongs_to :issuer_company, class_name: 'Company', optional: true
  belongs_to :sale_nature, class_name: 'OperationNature', optional: true
  belongs_to :transfer_nature, class_name: 'OperationNature', optional: true
  belongs_to :supply_issuer_company, class_name: 'Company', optional: true
  belongs_to :supply_nature, class_name: 'OperationNature', optional: true
  belongs_to :b2c_issuer_company, class_name: 'Company', optional: true
  belongs_to :b2c_nature, class_name: 'OperationNature', optional: true
  belongs_to :remessa_issuer_company, class_name: 'Company', optional: true
  belongs_to :remessa_nature, class_name: 'OperationNature', optional: true
  belongs_to :b2c_to_b2b_issuer_company, class_name: 'Company', optional: true
  belongs_to :b2c_to_b2b_nature, class_name: 'OperationNature', optional: true
  belongs_to :b2c_to_b2b_remessa_issuer_company, class_name: 'Company', optional: true
  belongs_to :b2c_to_b2b_remessa_nature, class_name: 'OperationNature', optional: true
  belongs_to :b2b_to_b2c_remessa_issuer_company, class_name: 'Company', optional: true
  belongs_to :b2b_to_b2c_remessa_nature, class_name: 'OperationNature', optional: true

  # Nota de remessa do abastecimento: destinatário padrão, o depósito do Correios Log+ em Contagem (como na
  # NF-e 15777). Dá para mudar nas configurações e, só num pedido, na aba Nota fiscal dele.
  REMESSA_RECIPIENT_FIELDS = %w[name document state_registration street number complement neighbourhood city state zip city_ibge_code].freeze
  REMESSA_DEFAULT_RECIPIENT = {
    'name' => 'CLI CONTAGEM', 'document' => '34.028.316/9005-20', 'state_registration' => '0620144620013',
    'street' => 'Avenida Wilson Tavares Ribeiro', 'number' => '1651', 'complement' => 'Docas 20 a 42 - LOG+',
    'neighbourhood' => 'Chacaras Reunidas Santa Terezinha', 'city' => 'Contagem', 'state' => 'MG', 'zip' => '32.183-680',
    'city_ibge_code' => '3118601'
  }.freeze

  # Só os campos conhecidos, como texto sem espaço sobrando (o JSON pode vir com chaves símbolo ou texto).
  def self.normalize_recipient(data)
    hash = (data || {}).to_h.transform_keys(&:to_s)
    REMESSA_RECIPIENT_FIELDS.to_h { |f| [f, hash[f].to_s.strip] }
  end

  # Colunas da empresa e da natureza de cada tipo de transferência.
  TRANSFER_KINDS = { 'stock_transfer' => %i[supply_issuer_company supply_nature], 'b2c_transfer' => %i[b2c_issuer_company b2c_nature] }.freeze

  validates :fixed_freight_value, numericality: { greater_than_or_equal_to: 0 }
  validates :seamless_discount_percent, :default_discount_percent, numericality: { greater_than_or_equal_to: 0, less_than: 100 }
  validate :natures_match_kind
  validate :natures_fit_issuer
  validate :b2c_to_b2b_branches_differ
  after_save :link_natures_to_issuer

  # Onde se escolhe a empresa e a natureza de cada tipo de pedido (para as mensagens).
  CONFIG_NAMES = { 'sale' => 'Configuração do atacado', 'stock_transfer' => 'Abastecimento Lojas → Configurações',
                   'b2c_transfer' => 'Transferências B2B ⇄ B2C → Configurações' }.freeze

  def self.config_name(order)
    CONFIG_NAMES.fetch(order.kind.to_s, CONFIG_NAMES['sale'])
  end

  # Onde se escolhe a empresa e a natureza da nota de remessa do pedido.
  def self.remessa_config_name(order)
    order.b2c_transfer? ? CONFIG_NAMES['b2c_transfer'] : CONFIG_NAMES['stock_transfer']
  end

  def self.current
    first || create!(fixed_freight_value: 0)
  end

  def self.seamless?(product)
    product&.shopify_product_name.to_s.downcase.include?('seamless')
  end

  def discount_percent_for(product)
    self.class.seamless?(product) ? seamless_discount_percent : default_discount_percent
  end

  # Preço sugerido do atacado: varejo com o desconto da categoria do produto.
  def wholesale_price_for(product)
    return nil unless product&.price.present?

    (product.price.to_d * (100 - discount_percent_for(product)) / 100).round(2).to_f
  end

  # Sem escolha salva, valem os padrões combinados: a empresa 0002-55, "Atacado" e "Transferência entre Filiais".
  # Com o pedido (ou o tipo), a empresa escolhida para aquele tipo de transferência vem antes.
  def issuer(order = nil)
    return b2c_to_b2b_issuer if b2c_to_b2b?(order)

    own = (cols = TRANSFER_KINDS[kind_of(order)]) && public_send(cols[0])
    own || issuer_company || company_with_cnpj(DEFAULT_ISSUER_CNPJ)
  end

  # B2C → B2B: sem escolha, a transferência sai pela empresa com o CNPJ da filial B2C.
  def b2c_to_b2b_issuer
    b2c_to_b2b_issuer_company || company_with_cnpj(B2bOrderType.b2c_cnpj)
  end

  # Remessa do abastecimento: sem escolha, sai pela empresa do abastecimento. Remessa do B2C → B2B: sem escolha,
  # pela empresa que emite a transferência B2B → B2C, a filial B2B (que também recebe a nota de transferência).
  # Remessa do B2B → B2C: sem escolha, pela filial B2C, que recebe a nota de transferência.
  def remessa_issuer(order = nil)
    return b2c_to_b2b_remessa_issuer_company || issuer('b2c_transfer') if b2c_to_b2b?(order)
    return b2b_to_b2c_remessa_issuer_company || b2c_to_b2b_issuer if b2b_to_b2c?(order)

    remessa_issuer_company || issuer('stock_transfer')
  end

  def remessa_nature_for(order = nil)
    return b2c_to_b2b_remessa_nature || remessa_nature if b2c_to_b2b?(order)
    return b2b_to_b2c_remessa_nature || remessa_nature if b2b_to_b2c?(order)

    remessa_nature
  end

  def remessa_recipient_data(order = nil)
    own = if b2c_to_b2b?(order) then b2c_to_b2b_remessa_recipient.presence
          elsif b2b_to_b2c?(order) then b2b_to_b2c_remessa_recipient.presence
          end
    self.class.normalize_recipient(own || remessa_recipient.presence || REMESSA_DEFAULT_RECIPIENT)
  end

  def nature_for(order)
    return b2c_to_b2b_nature || default_transfer_nature if b2c_to_b2b?(order)

    kind = kind_of(order)
    if kind == 'sale'
      sale_nature || OperationNature.sale.where(active: true).find_by(description: DEFAULT_SALE_NATURE)
    else
      (TRANSFER_KINDS[kind] && public_send(TRANSFER_KINDS[kind][1])) || default_transfer_nature
    end
  end

  private

  def b2c_to_b2b?(order)
    order.to_s == 'b2c_to_b2b' || (order.respond_to?(:b2c_to_b2b?) && order.b2c_to_b2b?)
  end

  # Pedido de transferência B2C no sentido B2B → B2C (o atacado e o abastecimento também guardam o sentido
  # padrão b2b_to_b2c, então o tipo do pedido conta).
  def b2b_to_b2c?(order)
    order.to_s == 'b2b_to_b2c' || (order.respond_to?(:b2c_transfer?) && order.b2c_transfer? && order.b2b_to_b2c?)
  end

  def default_transfer_nature
    transfer_nature || OperationNature.transfer.where(active: true).where('description LIKE ?', "#{DEFAULT_TRANSFER_NATURE}%").first
  end

  def company_with_cnpj(digits)
    Company.where("REPLACE(REPLACE(REPLACE(cnpj, '.', ''), '/', ''), '-', '') = ?", digits).first
  end

  def kind_of(order)
    order.respond_to?(:kind) ? order.kind.to_s : order.to_s
  end

  # [empresa, natureza] de cada tipo, com as escolhas da tela (ou os padrões) para conferir o regime.
  def issuer_nature_pairs
    [[issuer('sale'), sale_nature], [issuer('stock_transfer'), supply_nature || transfer_nature],
     [issuer('b2c_transfer'), b2c_nature || transfer_nature], [remessa_issuer, remessa_nature],
     [b2c_to_b2b_issuer, b2c_to_b2b_nature], [remessa_issuer('b2c_to_b2b'), b2c_to_b2b_remessa_nature],
     [remessa_issuer('b2b_to_b2c'), b2b_to_b2c_remessa_nature]]
  end

  def natures_match_kind
    errors.add(:sale_nature, 'precisa ser uma natureza de venda') if sale_nature && !sale_nature.sale?
    { transfer_nature: transfer_nature, supply_nature: supply_nature, b2c_nature: b2c_nature, b2c_to_b2b_nature: b2c_to_b2b_nature }.each do |attr, nature|
      errors.add(attr, 'precisa ser uma natureza de transferência') if nature && !nature.transfer?
    end
  end

  # CSOSN só para empresa do Simples; CST só para Regime Normal (mesma regra do vínculo).
  def natures_fit_issuer
    issuer_nature_pairs.each do |company, nature|
      next if company.nil? || nature.nil? || nature.compatible_with?(company)

      message = "A natureza \"#{nature.description}\" usa #{nature.regime_label} e não serve para #{company.legal_name}."
      errors.add(:base, message) unless errors[:base].include?(message)
    end
  end

  # A nota de transferência B2C → B2B vai de uma filial para a outra: emitente e destinatário não podem coincidir.
  def b2c_to_b2b_branches_differ
    return if b2c_to_b2b_issuer_company_id.blank? || b2c_to_b2b_issuer_company_id != b2c_to_b2b_remessa_issuer_company_id

    errors.add(:base, 'No B2C → B2B, a filial B2C e a filial B2B precisam ser empresas diferentes.')
  end

  # A emissão só aceita natureza vinculada à empresa: escolher aqui já vincula.
  def link_natures_to_issuer
    issuer_nature_pairs.each do |company, nature|
      CompanyOperationNature.find_or_create_by!(company:, operation_nature: nature) if company && nature
    end
  end
end
