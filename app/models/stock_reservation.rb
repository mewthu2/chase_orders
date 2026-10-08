# Item de um pedido que está na fila do Tiny (preparando_envio, ainda sem pedido no Correios Log).
# A tabela é uma foto refeita pelo StockReservationRefresher a cada 10 min.
class StockReservation < ApplicationRecord
  enum :account, { b2b: 0, b2c: 1 }

  before_validation { self.sku = sku.to_s.strip.upcase }

  validates :tiny_order_id, :sku, presence: true

  def self.reserved_for(sku, account:)
    where(account: account.to_s, sku: sku.to_s.strip.upcase).sum(:quantity).ceil
  end
end
