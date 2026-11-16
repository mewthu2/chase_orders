# Configuração do atacado (uma linha só):
# - fixed_freight_value: antigo frete fixo, substituído pela Tabela de frete (B2bFreightRate);
# - seamless_discount_percent / default_discount_percent: desconto sobre o preço de varejo que dá o preço
#   sugerido do item no pedido do atacado (Seamless = produto com "Seamless" no nome; o resto usa o padrão);
# - issuer_company / sale_nature: quem emite a NF-e dos pedidos de atacado do Log02 feitos no Honey e com
#   que natureza;
# - supply_issuer_company / supply_nature e b2c_issuer_company / b2c_nature: o mesmo para o abastecimento das
#   lojas e para a transferência B2C (nas Configurações de cada tela). Sem escolha, valem a empresa do atacado
#   e transfer_nature (a natureza de transferência de antes, comum aos dois).
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

  # Colunas da empresa e da natureza de cada tipo de transferência.
  TRANSFER_KINDS = { 'stock_transfer' => %i[supply_issuer_company supply_nature], 'b2c_transfer' => %i[b2c_issuer_company b2c_nature] }.freeze

  validates :fixed_freight_value, numericality: { greater_than_or_equal_to: 0 }
  validates :seamless_discount_percent, :default_discount_percent, numericality: { greater_than_or_equal_to: 0, less_than: 100 }
  validate :natures_match_kind
  validate :natures_fit_issuer
  after_save :link_natures_to_issuer

  # Onde se escolhe a empresa e a natureza de cada tipo de pedido (para as mensagens).
  CONFIG_NAMES = { 'sale' => 'Configuração do atacado', 'stock_transfer' => 'Abastecimento Lojas → Configurações',
                   'b2c_transfer' => 'Transferência B2B → B2C → Configurações' }.freeze

  def self.config_name(order)
    CONFIG_NAMES.fetch(order.kind.to_s, CONFIG_NAMES['sale'])
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
    own = (cols = TRANSFER_KINDS[kind_of(order)]) && public_send(cols[0])
    own || issuer_company || Company.where("REPLACE(REPLACE(REPLACE(cnpj, '.', ''), '/', ''), '-', '') = ?", DEFAULT_ISSUER_CNPJ).first
  end

  def nature_for(order)
    kind = kind_of(order)
    if kind == 'sale'
      sale_nature || OperationNature.sale.where(active: true).find_by(description: DEFAULT_SALE_NATURE)
    else
      (TRANSFER_KINDS[kind] && public_send(TRANSFER_KINDS[kind][1])) || transfer_nature ||
        OperationNature.transfer.where(active: true).where('description LIKE ?', "#{DEFAULT_TRANSFER_NATURE}%").first
    end
  end

  private

  def kind_of(order)
    order.respond_to?(:kind) ? order.kind.to_s : order.to_s
  end

  # [empresa, natureza] de cada tipo, com as escolhas da tela (ou os padrões) para conferir o regime.
  def issuer_nature_pairs
    [[issuer('sale'), sale_nature], [issuer('stock_transfer'), supply_nature || transfer_nature],
     [issuer('b2c_transfer'), b2c_nature || transfer_nature]]
  end

  def natures_match_kind
    errors.add(:sale_nature, 'precisa ser uma natureza de venda') if sale_nature && !sale_nature.sale?
    { transfer_nature: transfer_nature, supply_nature: supply_nature, b2c_nature: b2c_nature }.each do |attr, nature|
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

  # A emissão só aceita natureza vinculada à empresa: escolher aqui já vincula.
  def link_natures_to_issuer
    issuer_nature_pairs.each do |company, nature|
      CompanyOperationNature.find_or_create_by!(company:, operation_nature: nature) if company && nature
    end
  end
end
