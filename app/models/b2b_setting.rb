# Configuração do atacado (uma linha só):
# - fixed_freight_value: antigo frete fixo, substituído pela Tabela de frete (B2bFreightRate);
# - seamless_discount_percent / default_discount_percent: desconto sobre o preço de varejo que dá o preço
#   sugerido do item no pedido do atacado (Seamless = produto com "Seamless" no nome; o resto usa o padrão);
# - issuer_company / sale_nature / transfer_nature: quem emite a NF-e dos pedidos do Log02 feitos no Honey e
#   com que natureza (venda para o atacado; transferência para abastecimento e transferência B2C).
class B2bSetting < ApplicationRecord
  DEFAULT_ISSUER_CNPJ = '25405327000255'.freeze
  DEFAULT_SALE_NATURE = 'Atacado'.freeze
  DEFAULT_TRANSFER_NATURE = 'Transferência entre Filiais'.freeze

  belongs_to :issuer_company, class_name: 'Company', optional: true
  belongs_to :sale_nature, class_name: 'OperationNature', optional: true
  belongs_to :transfer_nature, class_name: 'OperationNature', optional: true

  validates :fixed_freight_value, numericality: { greater_than_or_equal_to: 0 }
  validates :seamless_discount_percent, :default_discount_percent, numericality: { greater_than_or_equal_to: 0, less_than: 100 }
  validate :natures_match_kind
  validate :natures_fit_issuer
  after_save :link_natures_to_issuer

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
  def issuer
    issuer_company || Company.where("REPLACE(REPLACE(REPLACE(cnpj, '.', ''), '/', ''), '-', '') = ?", DEFAULT_ISSUER_CNPJ).first
  end

  def nature_for(order)
    if order.sale?
      sale_nature || OperationNature.sale.where(active: true).find_by(description: DEFAULT_SALE_NATURE)
    else
      transfer_nature || OperationNature.transfer.where(active: true).where('description LIKE ?', "#{DEFAULT_TRANSFER_NATURE}%").first
    end
  end

  private

  def natures_match_kind
    errors.add(:sale_nature, 'precisa ser uma natureza de venda') if sale_nature && !sale_nature.sale?
    errors.add(:transfer_nature, 'precisa ser uma natureza de transferência') if transfer_nature && !transfer_nature.transfer?
  end

  # CSOSN só para empresa do Simples; CST só para Regime Normal (mesma regra do vínculo).
  def natures_fit_issuer
    company = issuer
    return unless company

    [sale_nature, transfer_nature].compact.each do |nature|
      next if nature.compatible_with?(company)

      errors.add(:base, "A natureza \"#{nature.description}\" usa #{nature.regime_label} e não serve para #{company.legal_name}.")
    end
  end

  # A emissão só aceita natureza vinculada à empresa: escolher aqui já vincula.
  def link_natures_to_issuer
    company = issuer
    return unless company

    [sale_nature, transfer_nature].compact.each do |nature|
      CompanyOperationNature.find_or_create_by!(company:, operation_nature: nature)
    end
  end
end
