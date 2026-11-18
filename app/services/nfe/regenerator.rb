module Nfe
  # Gera, sem emitir, a nota que substitui uma cancelada: mesmo pedido B2B ou remessa da Transferência Interna,
  # mesmo ambiente, com a empresa e a natureza configuradas agora (o motivo do cancelamento pode ter sido a
  # configuração). A nova fica em rascunho: assinada, com DANFE e XML para conferir, até alguém clicar em Emitir.
  # Pedido da Shopify não passa por aqui: a tela de emissão da Shopify tem o "Só gerar".
  class Regenerator
    class Error < StandardError; end

    def self.call(note)
      new(note).call
    end

    def initialize(note)
      @note = note
    end

    def call
      raise Error, 'Só dá para gerar outra nota no lugar de uma cancelada.' unless @note.cancelada?

      draft = if @note.b2b_order && @note.remessa? then from_remessa(@note.b2b_order)
              elsif @note.b2b_order then from_b2b_order(@note.b2b_order)
              elsif @note.internal_transfer_shipment then from_shipment(@note.internal_transfer_shipment)
              else raise Error, 'Esta nota não tem pedido ou remessa de origem no Honey.'
              end
      draft.update!(status: :rascunho)
      draft
    rescue Generator::Error, TransferGenerator::Error, ActiveRecord::RecordInvalid => e
      raise Error, e.message
    end

    private

    def environment
      @note.environment
    end

    def ensure_production_allowed!(company)
      raise Error, company.production_block_message if @note.producao? && company.homologacao?
    end

    def from_b2b_order(order)
      setting = B2bSetting.current
      company = setting.issuer(order)
      nature = setting.nature_for(order)
      raise Error, "Escolha a empresa emissora e a natureza em #{B2bSetting.config_name(order)}." unless company && nature

      ensure_production_allowed!(company)
      CompanyOperationNature.find_or_create_by!(company:, operation_nature: nature)
      Generator.call(order:, company:, nature:, environment:)
    end

    # Remessa: com a empresa e a natureza configuradas para o tipo do pedido.
    def from_remessa(order)
      setting = B2bSetting.current
      company = setting.remessa_issuer(order)
      nature = setting.remessa_nature_for(order)
      raise Error, "Escolha a empresa e a natureza da nota de remessa em #{B2bSetting.remessa_config_name(order)}." unless company && nature

      ensure_production_allowed!(company)
      CompanyOperationNature.find_or_create_by!(company:, operation_nature: nature)
      Generator.call(order:, company:, nature:, environment:, role: 'remessa')
    end

    def from_shipment(shipment)
      origin, destination = InternalTransferInvoicer.companies_for(shipment)
      raise Error, 'Ligue as duas lojas a uma empresa (Empresas → Loja desta empresa) antes de gerar a nota.' unless origin && destination

      ensure_production_allowed!(origin)
      TransferGenerator.call(shipment:, company: origin, recipient_company: destination, environment:)
    end
  end
end
