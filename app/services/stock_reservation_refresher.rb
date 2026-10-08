# Fotografa a fila do Tiny (pedidos em preparando_envio que ainda não viraram pedido no Correios Log)
# em stock_reservations. Os itens de um pedido já fotografado não são buscados de novo: eles não
# mudam enquanto o pedido está na fila, e cada obtain_order gasta uma requisição do Tiny.
class StockReservationRefresher
  ACCOUNTS = {
    'b2b' => { token_env: 'TOKEN_TINY2_PRODUCTION', attempt_kind: :create_correios_order_tiny2, lookback: 8.weeks },
    'b2c' => { token_env: 'TOKEN_TINY3_PRODUCTION', attempt_kind: :create_correios_order, lookback: 4.weeks }
  }.freeze

  NO_RECORDS_CODE = '20'.freeze
  RATE_LIMIT_CODE = '6'.freeze
  RATE_LIMIT_MESSAGE = 'Limite de requisições do Tiny: alguns pedidos ficam para a próxima atualização.'.freeze

  class TinyError < StandardError; end

  def self.call(account) = new(account).call

  def initialize(account)
    @account = account.to_s
    @config = ACCOUNTS.fetch(@account)
    @refresh = StockReservationRefresh.for(@account)
  end

  def call
    return @refresh if @refresh.running_recently?

    @refresh.update!(status: 'running', message: nil)
    queue = pending_orders(fetch_queue)
    StockReservation.where(account: @account).where.not(tiny_order_id: queue.keys).delete_all
    rate_limited = store_new_orders(queue)
    @refresh.update!(status: rate_limited ? 'partial' : 'success', last_refreshed_at: Time.current,
                     message: rate_limited ? RATE_LIMIT_MESSAGE : nil)
    @refresh
  rescue StandardError => e
    Rails.logger.error "StockReservationRefresher(#{@account}): #{e.class} #{e.message}"
    @refresh.update!(status: 'error', message: e.message.to_s.first(255))
    @refresh
  end

  private

  def token = ENV.fetch(@config[:token_env])

  # Resumo de cada pedido da fila ({ id:, numero:, nome:, data_pedido: }), todas as páginas.
  def fetch_queue
    since = @config[:lookback].ago.strftime('%d/%m/%Y')
    orders = []
    page = 1

    loop do
      retorno = Tiny::Orders.get_orders_response('', 'preparando_envio', token, page, since) || {}
      break if retorno[:codigo_erro].to_s == NO_RECORDS_CODE
      raise TinyError, tiny_error(retorno) unless retorno[:status] == 'OK'

      orders.concat(Array(retorno[:pedidos]).map { |entry| entry[:pedido] })
      break if page >= retorno[:numero_paginas].to_i

      page += 1
    end

    orders
  end

  def pending_orders(orders)
    by_id = orders.index_by { |order| order[:id].to_s }
    created = Attempt.where(kinds: @config[:attempt_kind], status: :success, tiny_order_id: by_id.keys)
                     .pluck(:tiny_order_id).map(&:to_s)
    by_id.except(*created)
  end

  # Devolve true se o Tiny cortou por limite de requisições (o resto fica para a próxima rodada).
  def store_new_orders(queue)
    known = StockReservation.where(account: @account, tiny_order_id: queue.keys).distinct.pluck(:tiny_order_id)

    (queue.keys - known).each do |tiny_order_id|
      retorno = Tiny::Orders.obtain_order(token, tiny_order_id) || {}
      return true if retorno[:codigo_erro].to_s == RATE_LIMIT_CODE
      raise TinyError, tiny_error(retorno) unless retorno[:status] == 'OK'

      store_order(queue[tiny_order_id], retorno[:pedido])
    rescue TinyError, JSON::ParserError, HTTParty::Error, SocketError, Timeout::Error => e
      Rails.logger.error "StockReservationRefresher(#{@account}) pedido #{tiny_order_id}: #{e.class} #{e.message}"
    end

    false
  end

  def store_order(summary, pedido)
    quantities = Array(pedido[:itens]).each_with_object(Hash.new(0.to_d)) do |entry, acc|
      sku = entry.dig(:item, :codigo).to_s.strip.upcase
      acc[sku] += entry.dig(:item, :quantidade).to_s.tr(',', '.').to_d if sku.present?
    end
    return if quantities.empty?

    now = Time.current
    StockReservation.insert_all(quantities.map do |sku, quantity|
      { account: StockReservation.accounts[@account], tiny_order_id: summary[:id].to_s,
        tiny_order_number: summary[:numero].to_s, customer_name: summary[:nome].to_s.first(255),
        order_date: parse_date(summary[:data_pedido]), sku:, quantity:, created_at: now, updated_at: now }
    end)
  end

  def parse_date(value)
    Date.strptime(value.to_s, '%d/%m/%Y')
  rescue Date::Error
    nil
  end

  def tiny_error(retorno)
    errors = Array(retorno[:erros]).map { |e| e.is_a?(Hash) ? e[:erro] : e }.compact
    "Tiny: #{errors.join(', ').presence || "status #{retorno[:status].presence || 'ausente'}, código #{retorno[:codigo_erro].presence || 'ausente'}"}"
  end
end
