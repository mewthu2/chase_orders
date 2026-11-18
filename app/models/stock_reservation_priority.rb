# Escadinha da reserva de estoque: cada origem fica num degrau (1 é o mais prioritário), separada por estoque.
# Quem está num degrau só respeita as reservas do mesmo degrau ou de cima; as de baixo são ignoradas.
class StockReservationPriority < ApplicationRecord
  SOURCES = {
    'b2c_orders' => { account: 'b2c', label: 'Pedidos B2C', icon: 'fas fa-bag-shopping', default: 1,
                      hint: 'Pedidos da loja online na fila. Com algo acima ou no mesmo degrau, o estoque enviado à Shopify desconta essa reserva.' },
    'b2c_to_b2b' => { account: 'b2c', label: 'Transferência B2C → B2B', icon: 'fas fa-random', default: 2,
                      hint: 'Reserva até as duas notas de produção serem autorizadas.' },
    'sale' => { account: 'b2b', label: 'Pedidos de Atacado', icon: 'fas fa-handshake', default: 1,
                hint: 'Reserva até virar pedido no Correios.' },
    'stock_transfer' => { account: 'b2b', label: 'Abastecimento Lojas', icon: 'fas fa-dolly', default: 1,
                          hint: 'Reserva até virar pedido no Correios.' },
    'b2c_transfer' => { account: 'b2b', label: 'Transferência B2B → B2C', icon: 'fas fa-random', default: 1,
                        hint: 'Reserva até virar pedido no Correios.' }
  }.freeze
  ACCOUNTS = { 'b2c' => 'Estoque B2C (Log03)', 'b2b' => 'Estoque B2B (Log02)' }.freeze

  validates :source, inclusion: { in: SOURCES.keys }, uniqueness: true
  validate :level_fits_ladder

  def self.sources_of(account) = SOURCES.select { |_, data| data[:account] == account.to_s }.keys
  def self.account_of(source) = SOURCES.fetch(source.to_s)[:account]

  def self.levels
    SOURCES.transform_values { |data| data[:default] }.merge(pluck(:source, :level).to_h.slice(*SOURCES.keys))
  end

  # Origens cujas reservas contam para quem é de `source`: as do mesmo degrau e as de cima, no mesmo estoque.
  def self.counted_sources(source, levels: self.levels)
    sources_of(account_of(source)).select { |other| levels[other] <= levels[source.to_s] }
  end

  def self.ahead_of(source, levels: self.levels)
    counted_sources(source, levels:) - [source.to_s]
  end

  def self.save_levels!(values)
    transaction do
      values.to_h.slice(*SOURCES.keys).each do |source, level|
        find_or_initialize_by(source:).update!(level: level.to_i)
      end
    end
  end

  private

  def level_fits_ladder
    return unless SOURCES.key?(source)

    max = self.class.sources_of(self.class.account_of(source)).size
    errors.add(:level, "deve ficar entre 1 e #{max}") unless level.to_i.between?(1, max)
  end
end
