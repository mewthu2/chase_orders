# Procura pedidos travados na criação do Correios por falta de bairro ou número
# ("bairro não presente", "numero não presente") e completa o endereço com APIs públicas de CEP
# (AddressDataFixer). A correção fica salva no Honey; a próxima rodada da criação já usa o endereço novo.
#
# Roda sozinho ao fim de cada rodada da criação (B2C e B2B) e também pode ser chamado à mão:
#   FixAddressDataJob.perform_now            # todos os pendentes
#   FixAddressDataJob.perform_now(920697217) # um pedido
class FixAddressDataJob < ActiveJob::Base
  queue_as :default

  KINDS = {
    'create_correios_order' => 'TOKEN_TINY3_PRODUCTION',
    'create_correios_order_tiny2' => 'TOKEN_TINY2_PRODUCTION'
  }.freeze
  FIXABLE_ERROR = /\b(bairro|numero)\b.*não presente/
  LOOKBACK = 3.days

  def perform(tiny_order_id = nil)
    pending(tiny_order_id).each { |attempt| fix(attempt) }
  end

  # Último erro de cada pedido que ainda não foi criado e ainda não tem bairro/número corrigido.
  def pending(tiny_order_id = nil)
    scope = Attempt.where(kinds: KINDS.keys, status: :error).where('created_at >= ?', LOOKBACK.ago)
    scope = scope.where(tiny_order_id: tiny_order_id) if tiny_order_id
    latest = scope.order(:id).group_by(&:tiny_order_id).values.map(&:last)
    latest = latest.select { |attempt| attempt.error.to_s.match?(FIXABLE_ERROR) }
    return [] if latest.empty?

    ids = latest.map(&:tiny_order_id)
    created = Attempt.where(kinds: KINDS.keys, status: :success, tiny_order_id: ids).pluck(:tiny_order_id).to_set
    corrections = AddressCorrection.where(tiny_order_id: ids.map(&:to_s)).index_by(&:tiny_order_id)

    latest.reject do |attempt|
      created.include?(attempt.tiny_order_id) || already_fixed?(attempt, corrections[attempt.tiny_order_id.to_s])
    end
  end

  private

  def already_fixed?(attempt, correction)
    return false unless correction

    attempt.error.to_s.scan(/\b(bairro|numero)\b/).flatten.all? { |field| correction[field].present? }
  end

  def fix(attempt)
    pedido = Tiny::Orders.obtain_order(ENV.fetch(KINDS[attempt.kinds]), attempt.tiny_order_id)&.dig(:pedido)
    return unless pedido.present?

    address = pedido[:endereco_entrega].presence || pedido[:cliente]
    return unless address.present?

    AddressDataFixer.apply!(attempt.tiny_order_id, address.slice(:endereco, :numero, :complemento, :bairro, :cep, :cidade, :uf))
  rescue StandardError => e
    Rails.logger.warn("[FixAddressDataJob] pedido #{attempt.tiny_order_id}: #{e.message}")
  end
end
