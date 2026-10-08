# Reserva de Estoque Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reservar no Honey os itens da fila do Tiny (pedidos em `preparando_envio` ainda não criados no Correios Log), bloquear pedidos B2B acima do disponível (estoque Correios B2B − reserva) e mostrar as reservas em duas telas (B2B e B2C).

**Architecture:** Um serviço (`StockReservationRefresher`) fotografa a fila do Tiny2/Tiny3 na tabela `stock_reservations` a cada 10 min (rake no Heroku Scheduler + botão "Atualizar agora"). `B2bStockAvailability` combina o estoque do Correios B2B com a reserva e alimenta tanto o endpoint `product_stock` quanto a validação do `B2bOrdersController`. `StockReservationsController` exibe as reservas por conta.

**Tech Stack:** Rails 7.2, MySQL, Sidekiq/ActiveJob, Minitest + WebMock, ERB + JS puro, SCSS (paleta em `admin/variables`).

**Spec:** `docs/superpowers/specs/2026-10-08-stock-reservations-design.md`

**Ordem de execução:** 1 → 2 → 3 → **5 → 4** → 6 (a Task 4, formulário, usa a rota, a chave de tela, o partial e o SCSS criados na Task 5).

## Global Constraints

- **Nunca rodar `git commit`** (preferência do usuário). Nenhuma task tem passo de commit.
- **Nunca rodar `db:migrate`/`db:seed` no banco de development** — é o banco de produção. Migrations só são validadas no MySQL temporário de teste.
- Testes: MySQL 8.0 temporário (ver memória `project-dev-db-shared-and-test-env`), rodar com `TEST_DATABASE_URL=mysql2://root@127.0.0.1:3390/<banco_novo> PARALLEL_WORKERS=1 bin/rails test ...`. Baseline: 7 falhas preexistentes (home_controller, tickets/add_message, ticket_notifier, ticket_overdue_job).
- Intervalo de atualização: **10 minutos** (`StockReservationRefresh::INTERVAL = 10.minutes`).
- Conta B2B = Tiny2 (`TOKEN_TINY2_PRODUCTION`, attempt `create_correios_order_tiny2`, janela 8 semanas). Conta B2C = Tiny3 (`TOKEN_TINY3_PRODUCTION`, attempt `create_correios_order`, janela 4 semanas).
- B2C **não** desconta nada do sync Correios → Shopify.
- Textos de interface em português; visual vivo e animado (memória `feedback_lively_visual_design`).
- Partials SCSS importam `admin/variables`.

## Review Focus

1. **Tiny sem pedidos na fila** (retorno `codigo_erro: 20`, "A consulta não retornou registros") → tratar como fila vazia e apagar todas as reservas da conta, não como erro. Teste na Task 2.
2. **Limite de requisições do Tiny** (`codigo_erro: 6`) no meio dos `obtain_order` → gravar o que já veio, marcar `partial`, buscar o resto na próxima rodada. Teste na Task 2.
3. **Duas execuções simultâneas** (scheduler + botão) → a segunda é ignorada enquanto a primeira está `running` há < 5 min; um `running` travado há mais de 5 min não bloqueia para sempre. Teste na Task 2.
4. **Correios fora do ar ao salvar** → o pedido não é bloqueado pela reserva (comportamento atual preservado). Teste na Task 3.
5. **Mesmo SKU em duas linhas do pedido** (ou com maiúsculas/minúsculas diferentes) → quantidades somadas antes de comparar com o disponível. Teste na Task 3.

---

### Task 1: Tabelas e models de reserva

**Files:**
- Create: `db/migrate/20261008130000_create_stock_reservations.rb`
- Create: `app/models/stock_reservation.rb`
- Create: `app/models/stock_reservation_refresh.rb`
- Modify: `db/schema.rb` (gerado no banco limpo `chase_schema`, ver memória)
- Test: `test/models/stock_reservation_test.rb`, `test/models/stock_reservation_refresh_test.rb`

**Interfaces:**
- Produces:
  - `StockReservation` — enum `account: { b2b: 0, b2c: 1 }`; colunas `tiny_order_id, tiny_order_number, customer_name, order_date, sku, quantity`.
  - `StockReservation.reserved_for(sku, account:) -> Integer` (soma arredondada para cima).
  - `StockReservationRefresh.for(account) -> StockReservationRefresh` (cria se não existir).
  - `StockReservationRefresh#next_refresh_at -> Time|nil`, `#running_recently? -> Boolean`, `STATUSES`, `INTERVAL`, `STALE_RUN = 5.minutes`.

- [ ] **Step 1: Write the failing tests**

`test/models/stock_reservation_test.rb`:
```ruby
require 'test_helper'

class StockReservationTest < ActiveSupport::TestCase
  def reserve(account, sku, quantity, order_id: '1')
    StockReservation.create!(account:, tiny_order_id: order_id, sku:, quantity:)
  end

  test 'reserved_for sums quantities of the account only' do
    reserve(:b2b, 'LEG-A', 2, order_id: '1')
    reserve(:b2b, 'LEG-A', 2, order_id: '2')
    reserve(:b2c, 'LEG-A', 5, order_id: '3')

    assert_equal 4, StockReservation.reserved_for('LEG-A', account: :b2b)
    assert_equal 5, StockReservation.reserved_for('LEG-A', account: :b2c)
  end

  test 'sku is stored upcased and looked up case-insensitively' do
    reserve(:b2b, ' leg-a ', 1)

    assert_equal 'LEG-A', StockReservation.last.sku
    assert_equal 1, StockReservation.reserved_for('leg-a', account: :b2b)
  end

  test 'reserved_for is zero when nothing is reserved' do
    assert_equal 0, StockReservation.reserved_for('NONE', account: :b2b)
  end
end
```

`test/models/stock_reservation_refresh_test.rb`:
```ruby
require 'test_helper'

class StockReservationRefreshTest < ActiveSupport::TestCase
  test 'for creates one row per account and reuses it' do
    first = StockReservationRefresh.for(:b2b)
    assert_equal first, StockReservationRefresh.for('b2b')
    refute_equal first, StockReservationRefresh.for(:b2c)
    assert_equal 'idle', first.status
  end

  test 'next_refresh_at is ten minutes after the last refresh' do
    refresh = StockReservationRefresh.for(:b2b)
    assert_nil refresh.next_refresh_at

    time = Time.zone.parse('2026-10-08 10:00')
    refresh.update!(last_refreshed_at: time)
    assert_equal time + 10.minutes, refresh.next_refresh_at
  end

  test 'running_recently? ignores a run stuck for more than five minutes' do
    refresh = StockReservationRefresh.for(:b2b)
    refresh.update!(status: 'running')
    assert refresh.running_recently?

    refresh.update_columns(updated_at: 6.minutes.ago)
    refute refresh.running_recently?
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `TEST_DATABASE_URL=... PARALLEL_WORKERS=1 bin/rails test test/models/stock_reservation_test.rb test/models/stock_reservation_refresh_test.rb`
Expected: FAIL/ERROR com `uninitialized constant StockReservation`.

- [ ] **Step 3: Write migration and models**

`db/migrate/20261008130000_create_stock_reservations.rb`:
```ruby
class CreateStockReservations < ActiveRecord::Migration[7.2]
  def change
    create_table :stock_reservations do |t|
      t.integer :account, null: false
      t.string :tiny_order_id, null: false
      t.string :tiny_order_number
      t.string :customer_name
      t.date :order_date
      t.string :sku, null: false
      t.decimal :quantity, precision: 12, scale: 3, null: false, default: 0
      t.timestamps
    end
    add_index :stock_reservations, [:account, :sku]
    add_index :stock_reservations, [:account, :tiny_order_id]

    create_table :stock_reservation_refreshes do |t|
      t.integer :account, null: false
      t.datetime :last_refreshed_at
      t.string :status, null: false, default: 'idle'
      t.string :message
      t.timestamps
    end
    add_index :stock_reservation_refreshes, :account, unique: true
  end
end
```

`app/models/stock_reservation.rb`:
```ruby
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
```

`app/models/stock_reservation_refresh.rb`:
```ruby
# Estado da última atualização das reservas de cada conta (uma linha por conta).
class StockReservationRefresh < ApplicationRecord
  INTERVAL = 10.minutes
  STALE_RUN = 5.minutes
  STATUSES = %w[idle running success partial error].freeze

  enum :account, { b2b: 0, b2c: 1 }

  validates :status, inclusion: { in: STATUSES }

  def self.for(account)
    create_or_find_by!(account: account.to_s)
  end

  def next_refresh_at
    last_refreshed_at && last_refreshed_at + INTERVAL
  end

  # Um "running" mais velho que STALE_RUN é de uma execução que morreu no meio.
  def running_recently?
    status == 'running' && updated_at > STALE_RUN.ago
  end
end
```

- [ ] **Step 4: Apply migration on the temp test DB and regenerate schema**

Run (banco limpo `chase_schema` no MySQL temporário): `DATABASE_URL=mysql2://root@127.0.0.1:3390/chase_schema bin/rails db:create db:schema:load db:migrate` e confira que `db/schema.rb` ganhou só as duas tabelas novas (`git diff db/schema.rb`). Depois crie um banco de teste com nome novo (`db:create db:schema:load`).

- [ ] **Step 5: Run tests to verify they pass**

Run: mesmo comando do Step 2. Expected: PASS (6 testes).

---

### Task 2: Refresh da fila do Tiny (serviço, job, rake)

**Files:**
- Create: `app/services/stock_reservation_refresher.rb`
- Create: `app/jobs/stock_reservation_refresh_job.rb`
- Create: `lib/tasks/stock_reservations.rake`
- Test: `test/services/stock_reservation_refresher_test.rb`

**Interfaces:**
- Consumes: `StockReservation`, `StockReservationRefresh.for`, `#running_recently?` (Task 1); `Tiny::Orders.get_orders_response(kind, situacao, token, page, data)` e `Tiny::Orders.obtain_order(token, id)` (existentes; usam `ENV['PEDIDOS_PESQUISA']` e `ENV['OBTER_PEDIDO']`).
- Produces:
  - `StockReservationRefresher::ACCOUNTS` (chaves `'b2b'`, `'b2c'`).
  - `StockReservationRefresher.call(account) -> StockReservationRefresh` (status final: `success`, `partial`, `error`; ou inalterado se pulou por concorrência).
  - `StockReservationRefreshJob.perform_later(account = nil)` (nil = as duas contas).
  - Rake `stock_reservations:refresh`.

- [ ] **Step 1: Write the failing tests**

`test/services/stock_reservation_refresher_test.rb`:
```ruby
require 'test_helper'
require 'webmock/minitest'

class StockReservationRefresherTest < ActiveSupport::TestCase
  SEARCH_URL = 'https://tiny.example.com/pedidos.pesquisa.php'.freeze
  ORDER_URL = 'https://tiny.example.com/pedido.obter.php'.freeze

  def setup
    ENV['PEDIDOS_PESQUISA'] = SEARCH_URL
    ENV['OBTER_PEDIDO'] = ORDER_URL
    ENV['TOKEN_TINY2_PRODUCTION'] = 'tiny2'
    ENV['TOKEN_TINY3_PRODUCTION'] = 'tiny3'
  end

  def summary(id, numero: "N#{id}")
    { pedido: { id: id.to_s, numero: numero, nome: "Cliente #{id}", data_pedido: '07/10/2026' } }
  end

  def stub_queue(token, pedidos, pages: 1, page: 1)
    stub_request(:get, SEARCH_URL)
      .with(query: hash_including(token: token, situacao: 'preparando_envio', pagina: page.to_s))
      .to_return(body: { retorno: { status: 'OK', numero_paginas: pages, pedidos: pedidos } }.to_json)
  end

  def stub_empty_queue(token)
    stub_request(:get, SEARCH_URL).with(query: hash_including(token: token))
      .to_return(body: { retorno: { status: 'Erro', codigo_erro: '20', erros: [{ erro: 'A consulta não retornou registros' }] } }.to_json)
  end

  def stub_order(id, items)
    stub_request(:get, ORDER_URL).with(query: hash_including(id: id.to_s))
      .to_return(body: { retorno: { status: 'OK', pedido: { id: id.to_s, itens: items.map { |sku, qty| { item: { codigo: sku, quantidade: qty } } } } } }.to_json)
  end

  test 'stores the items of new queue orders' do
    stub_queue('tiny2', [summary(10)])
    stub_order(10, [['leg-a', '2.00'], ['TOP-B', '1.00']])

    refresh = StockReservationRefresher.call(:b2b)

    assert_equal 'success', refresh.status
    assert refresh.last_refreshed_at.present?
    assert_equal 2, StockReservation.reserved_for('LEG-A', account: :b2b)
    row = StockReservation.find_by(sku: 'TOP-B')
    assert_equal ['10', 'N10', 'Cliente 10', Date.new(2026, 10, 7)], [row.tiny_order_id, row.tiny_order_number, row.customer_name, row.order_date]
  end

  test 'follows every page of the queue' do
    stub_queue('tiny2', [summary(1)], pages: 2, page: 1)
    stub_queue('tiny2', [summary(2)], pages: 2, page: 2)
    stub_order(1, [['A', '1']])
    stub_order(2, [['A', '3']])

    StockReservationRefresher.call(:b2b)

    assert_equal 4, StockReservation.reserved_for('A', account: :b2b)
  end

  test 'orders already created in Correios are not reserved' do
    Attempt.create!(kinds: :create_correios_order_tiny2, status: :success, tiny_order_id: '10')
    stub_queue('tiny2', [summary(10)])

    StockReservationRefresher.call(:b2b)

    assert_equal 0, StockReservation.count
    assert_not_requested :get, ORDER_URL, query: hash_including(id: '10')
  end

  test 'removes orders that left the queue and keeps known ones without refetching' do
    StockReservation.create!(account: :b2b, tiny_order_id: '10', sku: 'A', quantity: 1)
    StockReservation.create!(account: :b2b, tiny_order_id: '99', sku: 'A', quantity: 5)
    StockReservation.create!(account: :b2c, tiny_order_id: '99', sku: 'A', quantity: 7)
    stub_queue('tiny2', [summary(10)])

    StockReservationRefresher.call(:b2b)

    assert_equal ['10'], StockReservation.b2b.pluck(:tiny_order_id)
    assert_equal 7, StockReservation.reserved_for('A', account: :b2c)
    assert_not_requested :get, ORDER_URL
  end

  test 'an empty queue clears the account reservations' do
    StockReservation.create!(account: :b2c, tiny_order_id: '5', sku: 'A', quantity: 1)
    stub_empty_queue('tiny3')

    refresh = StockReservationRefresher.call(:b2c)

    assert_equal 'success', refresh.status
    assert_equal 0, StockReservation.b2c.count
  end

  test 'a failing queue listing keeps the previous snapshot and records the error' do
    StockReservation.create!(account: :b2b, tiny_order_id: '10', sku: 'A', quantity: 1)
    stub_request(:get, SEARCH_URL).to_return(body: { retorno: { status: 'Erro', codigo_erro: '1', erros: [{ erro: 'Token inválido' }] } }.to_json)

    refresh = StockReservationRefresher.call(:b2b)

    assert_equal 'error', refresh.status
    assert_match(/Token inválido/, refresh.message)
    assert_equal 1, StockReservation.b2b.count
  end

  test 'rate limit while fetching items keeps what was stored and marks partial' do
    stub_queue('tiny2', [summary(1), summary(2)])
    stub_order(1, [['A', '1']])
    stub_request(:get, ORDER_URL).with(query: hash_including(id: '2'))
      .to_return(body: { retorno: { status: 'Erro', codigo_erro: '6' } }.to_json)

    refresh = StockReservationRefresher.call(:b2b)

    assert_equal 'partial', refresh.status
    assert_equal ['1'], StockReservation.b2b.distinct.pluck(:tiny_order_id)
  end

  test 'one broken order does not stop the others' do
    stub_queue('tiny2', [summary(1), summary(2)])
    stub_request(:get, ORDER_URL).with(query: hash_including(id: '1')).to_return(body: 'not json')
    stub_order(2, [['A', '1']])

    refresh = StockReservationRefresher.call(:b2b)

    assert_equal 'success', refresh.status
    assert_equal ['2'], StockReservation.b2b.distinct.pluck(:tiny_order_id)
  end

  test 'skips when another run is in progress, but not when that run is stale' do
    StockReservationRefresh.for(:b2b).update!(status: 'running')
    StockReservationRefresher.call(:b2b)
    assert_not_requested :get, SEARCH_URL

    StockReservationRefresh.for(:b2b).update_columns(updated_at: 6.minutes.ago)
    stub_empty_queue('tiny2')
    assert_equal 'success', StockReservationRefresher.call(:b2b).status
  end

  test 'the job refreshes both accounts when none is given' do
    stub_empty_queue('tiny2')
    stub_empty_queue('tiny3')

    StockReservationRefreshJob.perform_now

    assert_equal %w[success success], StockReservationRefresh.order(:account).pluck(:status)
  end
end
```

> Nota: confira os nomes de coluna de `Attempt` (`kinds`, `status`, `tiny_order_id`) em `db/schema.rb` antes de rodar; se `Attempt` tiver validações obrigatórias, preencha-as no `create!`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `... bin/rails test test/services/stock_reservation_refresher_test.rb`
Expected: ERROR `uninitialized constant StockReservationRefresher`.

- [ ] **Step 3: Implement service, job and rake task**

`app/services/stock_reservation_refresher.rb`:
```ruby
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
```

`app/jobs/stock_reservation_refresh_job.rb`:
```ruby
class StockReservationRefreshJob < ActiveJob::Base
  queue_as :default

  def perform(account = nil)
    accounts = account.present? ? [account.to_s] : StockReservationRefresher::ACCOUNTS.keys
    accounts.each { |acc| StockReservationRefresher.call(acc) }
  end
end
```

`lib/tasks/stock_reservations.rake`:
```ruby
namespace :stock_reservations do
  desc 'Atualiza as reservas de estoque da fila do Tiny (agendar no Heroku Scheduler a cada 10 min)'
  task refresh: :environment do
    StockReservationRefreshJob.perform_now
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `... bin/rails test test/services/stock_reservation_refresher_test.rb`
Expected: PASS (10 testes).

---

### Task 3: Disponível B2B (estoque − reserva) no endpoint e bloqueio ao salvar

**Files:**
- Create: `app/services/b2b_stock_availability.rb`
- Modify: `app/controllers/b2b_orders_controller.rb` (`create` :34, `update` :48, `transmit` :64, `product_stock` :154, remover `correios_stock_for` :306-316)
- Modify: `test/test_helper.rb` (stub padrão de estoque Correios farto)
- Test: `test/services/b2b_stock_availability_test.rb`, `test/controllers/b2b_orders_stock_reservation_test.rb`

**Interfaces:**
- Consumes: `StockReservation.reserved_for(sku, account: :b2b)` (Task 1); `Correios::Orders.get_stock(sku, from_tiny2: true)`.
- Produces:
  - `B2bStockAvailability.for_sku(sku) -> Result` com `sku, stock, reserved, available, status` (`'high'|'low'|'out'|'error'`), `#error?`.
  - `B2bStockAvailability.shortages(items) -> Array<Hash>` com `:sku, :requested, :stock, :reserved, :available`.
  - JSON de `GET product_stock`: `{ success, quantity (= disponível), stock, reserved, status }`.

- [ ] **Step 1: Write the failing tests**

`test/services/b2b_stock_availability_test.rb`:
```ruby
require 'test_helper'
require 'webmock/minitest'

class B2bStockAvailabilityTest < ActiveSupport::TestCase
  def setup
    ENV['CORREIOS_ESTOQUE'] = 'https://correios-log.example.com/estoque/'
    ENV['CORREIOS_CARTAO_POSTAGEM_2'] = 'fake-cartao-2'
    ENV['TOKEN_LOG_PRODUCTION2'] = 'fake-token-2'
  end

  def stub_stock(sku, disponivel)
    stub_request(:get, "https://correios-log.example.com/estoque/#{sku}/estoque")
      .to_return(status: 200, body: { disponivel: disponivel }.to_json)
  end

  test 'available is Correios stock minus the B2B reservation' do
    stub_stock('LEG-A', 3)
    StockReservation.create!(account: :b2b, tiny_order_id: '1', sku: 'LEG-A', quantity: 4)
    StockReservation.create!(account: :b2c, tiny_order_id: '2', sku: 'LEG-A', quantity: 50)

    result = B2bStockAvailability.for_sku('leg-a')

    assert_equal [3, 4, -1, 'out'], [result.stock, result.reserved, result.available, result.status]
  end

  test 'Correios failure gives an error result' do
    stub_request(:get, 'https://correios-log.example.com/estoque/LEG-A/estoque').to_return(status: 500)

    assert B2bStockAvailability.for_sku('LEG-A').error?
  end

  test 'shortages sums repeated skus and ignores items marked for destruction' do
    stub_stock('LEG-A', 5)
    StockReservation.create!(account: :b2b, tiny_order_id: '1', sku: 'LEG-A', quantity: 2)
    items = [B2bOrderItem.new(sku: 'LEG-A', quantity: 2), B2bOrderItem.new(sku: 'leg-a', quantity: 2)]
    removed = B2bOrderItem.new(sku: 'LEG-A', quantity: 50)
    removed.mark_for_destruction

    shortages = B2bStockAvailability.shortages(items + [removed])

    assert_equal [{ sku: 'LEG-A', requested: 4, stock: 5, reserved: 2, available: 3 }], shortages
  end

  test 'shortages ignores skus whose stock could not be read' do
    stub_request(:get, 'https://correios-log.example.com/estoque/LEG-A/estoque').to_timeout

    assert_empty B2bStockAvailability.shortages([B2bOrderItem.new(sku: 'LEG-A', quantity: 99)])
  end
end
```

`test/controllers/b2b_orders_stock_reservation_test.rb`:
```ruby
require 'test_helper'
require 'webmock/minitest'

class B2bOrdersStockReservationTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(name: 'Admin Reserva', email: 'admin_reserva@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @client = Client.create!(responsible_name: 'Cliente Reserva', registration: '25.405.327/0001-74')
    Product.create!(sku: 'LEG-A', shopify_product_name: 'Legging A', image_url: 'https://img.example.com/a.png')

    ENV['CORREIOS_ESTOQUE'] = 'https://correios-log.example.com/estoque/'
    ENV['CORREIOS_CARTAO_POSTAGEM_2'] = 'fake-cartao-2'
    ENV['TOKEN_LOG_PRODUCTION2'] = 'fake-token-2'
    ENV['TOKEN_TINY2_PRODUCTION'] = 'fake-token-tiny2'
    stub_request(:get, 'https://correios-log.example.com/estoque/LEG-A/estoque')
      .to_return(status: 200, body: { disponivel: 3 }.to_json)
    StockReservation.create!(account: :b2b, tiny_order_id: '77', sku: 'LEG-A', quantity: 2)
    sign_in @admin
  end

  def order_params(quantity)
    { b2b_order: { client_id: @client.id, b2b_order_items_attributes: { '0' => { sku: 'LEG-A', name: 'Legging A', quantity: quantity, price: 10 } } } }
  end

  test 'product_stock returns stock, reserved and available' do
    get product_stock_b2b_orders_path, params: { sku: 'LEG-A' }
    json = JSON.parse(response.body)

    assert_equal [3, 2, 1, 'low'], json.values_at('stock', 'reserved', 'quantity', 'status')
  end

  test 'create is blocked when an item exceeds the available stock' do
    assert_no_difference('B2bOrder.count') { post b2b_orders_path, params: order_params(2) }

    assert_response :unprocessable_entity
    assert_match(/LEG-A: pedido 2, disponível 1/, response.body)
    assert_match(/2 reservados na fila/, response.body)
  end

  test 'update of an order not yet in Tiny is blocked too' do
    order = B2bOrder.new(kind: :sale, user: @admin, client: @client, status: :aberto)
    order.b2b_order_items.build(sku: 'LEG-A', quantity: 1, price: 10)
    order.save!
    item = order.b2b_order_items.first

    patch b2b_order_path(order), params: { b2b_order: { b2b_order_items_attributes: { '0' => { id: item.id, quantity: 5 } } } }

    assert_response :unprocessable_entity
    assert_equal 1, item.reload.quantity
  end

  test 'orders already in Tiny are not blocked by their own reservation' do
    order = B2bOrder.new(kind: :sale, user: @admin, client: @client, status: :preparando_envio, tiny_reference_id: '77')
    order.b2b_order_items.build(sku: 'LEG-A', quantity: 5, price: 10)
    order.save!

    patch b2b_order_path(order), params: { b2b_order: { observations: 'x' } }

    refute_equal 422, response.status
  end

  test 'transmit is blocked when an item exceeds the available stock' do
    order = B2bOrder.new(kind: :sale, user: @admin, client: @client, status: :dados_incompletos)
    order.b2b_order_items.build(sku: 'LEG-A', quantity: 3, price: 10)
    order.save!

    post transmit_b2b_order_path(order)

    assert_match(/disponível 1/, flash[:alert])
    assert_not_requested :post, 'https://api.tiny.com.br/api2/pedido.incluir.php'
  end

  test 'Correios being down does not block the order' do
    stub_request(:get, 'https://correios-log.example.com/estoque/LEG-A/estoque').to_return(status: 503)
    stub_request(:post, 'https://api.tiny.com.br/api2/pedido.incluir.php')
      .to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '1', numero: '2' } } } }.to_json)

    assert_difference('B2bOrder.count', 1) { post b2b_orders_path, params: order_params(50) }
  end
end
```

> Antes de rodar: confira em `b2b_order_params` se `observations` existe; se não, use outro atributo permitido (ex.: `notes`). Confira também se `transmit` exige `resendable?` para `dados_incompletos` sem `tiny_reference_id` — ajuste o status do pedido do teste para um que seja reenviável.

- [ ] **Step 2: Run tests to verify they fail**

Run: `... bin/rails test test/services/b2b_stock_availability_test.rb test/controllers/b2b_orders_stock_reservation_test.rb`
Expected: ERROR `uninitialized constant B2bStockAvailability` e falhas no controller.

- [ ] **Step 3: Implement the availability service**

`app/services/b2b_stock_availability.rb`:
```ruby
# Estoque do Correios B2B descontando o que está reservado na fila do Tiny2 (StockReservation b2b).
# Vale para todos os pedidos B2B: venda/atacado, abastecimento e transferência B2C.
class B2bStockAvailability
  Result = Struct.new(:sku, :stock, :reserved, :available, :status, keyword_init: true) do
    def error? = status == 'error'
  end

  def self.for_sku(sku)
    sku = sku.to_s.strip.upcase
    reserved = StockReservation.reserved_for(sku, account: :b2b)
    stock = correios_stock(sku)
    return Result.new(sku:, stock: 0, reserved:, available: 0, status: 'error') if stock.nil?

    available = stock - reserved
    Result.new(sku:, stock:, reserved:, available:, status: status_for(available))
  end

  # Itens acima do disponível. SKUs sem resposta do Correios não entram (não bloqueiam).
  def self.shortages(items)
    requested = items.reject(&:marked_for_destruction?).each_with_object(Hash.new(0)) do |item, acc|
      sku = item.sku.to_s.strip.upcase
      acc[sku] += item.quantity.to_i if sku.present?
    end

    requested.filter_map do |sku, quantity|
      result = for_sku(sku)
      next if result.error? || quantity <= result.available

      { sku:, requested: quantity, stock: result.stock, reserved: result.reserved, available: result.available }
    end
  end

  def self.status_for(available)
    return 'high' if available > 10

    available.positive? ? 'low' : 'out'
  end

  def self.correios_stock(sku)
    response = Correios::Orders.get_stock(sku, from_tiny2: true)
    return nil unless response.respond_to?(:success?) && response.success?

    JSON.parse(response.body)['disponivel'].to_i
  rescue StandardError, Timeout::Error => e
    Rails.logger.error "B2bStockAvailability(#{sku}): #{e.class} #{e.message}"
    nil
  end
end
```

- [ ] **Step 4: Wire it into the controller**

Em `app/controllers/b2b_orders_controller.rb`:

`create` — trocar `if @b2b_order.save` por:
```ruby
    if @b2b_order.valid? && stock_available?(@b2b_order) && @b2b_order.save
```

`update` — trocar `if @b2b_order.save` por:
```ruby
    if @b2b_order.valid? && stock_available?(@b2b_order) && @b2b_order.save
```

`transmit` — logo após o bloco `unless @b2b_order.resendable?`:
```ruby
    unless stock_available?(@b2b_order)
      redirect_to orders_path_for(order_kind), alert: @b2b_order.errors.full_messages.to_sentence
      return
    end
```

`product_stock` — trocar `render json: { success: true, **correios_stock_for(product) }` por:
```ruby
    result = B2bStockAvailability.for_sku(product.sku)
    render json: { success: true, quantity: result.available, stock: result.stock, reserved: result.reserved, status: result.status }
```

Remover `correios_stock_for` e adicionar na seção `private`:
```ruby
  # Bloqueia itens acima do disponível no Correios B2B (estoque − reservas da fila do Tiny2). Só vale
  # enquanto o pedido não chegou ao Tiny: depois disso os itens dele já estão na própria reserva.
  def stock_available?(order)
    return true if order.tiny_reference_id.present? || order.cancelado?

    shortages = B2bStockAvailability.shortages(order.b2b_order_items)
    shortages.each do |s|
      order.errors.add(:base, "#{s[:sku]}: pedido #{s[:requested]}, disponível #{s[:available]} " \
                              "(estoque #{s[:stock]}, #{s[:reserved]} reservados na fila)")
    end
    shortages.empty?
  end
```

Confira com `grep -n correios_stock_for app/` que não sobrou nenhuma referência.

- [ ] **Step 5: Default plentiful stock stub for the rest of the suite**

Os testes existentes que fazem `post b2b_orders_path`/`transmit` passam a consultar o Correios. Em `test/test_helper.rb`, dentro de `class ActionDispatch::IntegrationTest`:
```ruby
  # O bloqueio por reserva consulta o estoque do Correios ao salvar pedidos B2B. Por padrão o estoque
  # é farto; testes que exercitam o estoque registram o próprio stub, que tem prioridade.
  setup do
    if defined?(WebMock)
      WebMock::API.stub_request(:get, %r{/estoque\z}).to_return(status: 200, body: { disponivel: 999_999 }.to_json)
    end
  end
```

- [ ] **Step 6: Run the new and the existing B2B tests**

Run: `... bin/rails test test/services/b2b_stock_availability_test.rb test/controllers/b2b_orders_stock_reservation_test.rb test/controllers/b2b_orders_controller_test.rb test/controllers/b2b_orders_kind_separation_test.rb test/controllers/b2c_transfers_test.rb test/controllers/b2b_orders_cancel_in_tiny_test.rb test/controllers/flash_messages_test.rb test/controllers/b2b_orders_destroy_test.rb`
Expected: PASS (incluindo `product_stock returns stock from the Correios API` → disponível 3, `low`).

---

### Task 4: Formulário do pedido B2B — Estoque / Reservado / Disponível e bloqueio ao adicionar

**Files:**
- Reuse: `app/views/stock_reservations/_freshness.html.erb` e `app/assets/stylesheets/admin/pages/_stock_reservations.scss` (criados na Task 5 com o conteúdo dos Steps 3 e 5 abaixo)
- Modify: `app/views/b2b_orders/_form.html.erb` (seção Itens :120-170, `addItemRow` :377-392, `queueStockFetch` :419-436, `renderPickerStock`/`fetchPickerStock` :497-524, `renderPickerResults` :575-630)
- Test: `test/controllers/b2b_orders_stock_reservation_test.rb` (adicionar)

**Interfaces:**
- Consumes: JSON de `product_stock` (Task 3): `quantity` (disponível), `stock`, `reserved`, `status`; `StockReservationRefresh.for(:b2b)` (Task 1); rota `b2b_stock_reservations_path` e chave de tela `stock_reservations_b2b` (Task 5, que roda antes desta).
- Produces: partial `stock_reservations/_freshness` com local `refresh:` (usado também na Task 5).

- [ ] **Step 1: Write the failing test**

Adicionar em `test/controllers/b2b_orders_stock_reservation_test.rb`:
```ruby
  test 'the order form shows when reservations were refreshed and when the next refresh happens' do
    StockReservationRefresh.for(:b2b).update!(status: 'success', last_refreshed_at: Time.zone.parse('2026-10-08 10:00'))

    get new_b2b_order_path

    assert_select '.reservation-freshness', text: /10:00/
    assert_select '.reservation-freshness', text: /10:10/
    assert_select 'th', text: /Estoque · Reservado · Disponível/
    assert_no_match(/só informativo/, response.body)
  end

  test 'the form enforces stock only while the order has not reached Tiny' do
    get new_b2b_order_path
    assert_select "#itemsTable[data-enforce-stock='true']"

    order = B2bOrder.new(kind: :sale, user: @admin, client: @client, status: :preparando_envio, tiny_reference_id: '77')
    order.b2b_order_items.build(sku: 'LEG-A', quantity: 5, price: 10)
    order.save!
    get edit_b2b_order_path(order)
    assert_select "#itemsTable[data-enforce-stock='false']"
  end
```

> Confira o nome da rota de "novo pedido de venda" em `config/routes.rb` (`new_b2b_order_path` ou equivalente) e ajuste.

- [ ] **Step 2: Run test to verify it fails**

Run: `... bin/rails test test/controllers/b2b_orders_stock_reservation_test.rb -n /freshness/`
Expected: FAIL (`.reservation-freshness` não encontrado).

- [ ] **Step 3: Freshness partial (conteúdo canônico — criado na Task 5; aqui só confira)**

`app/views/stock_reservations/_freshness.html.erb`:
```erb
<%# Quando a reserva foi atualizada e quando será a próxima atualização. local: refresh (StockReservationRefresh) %>
<div class="reservation-freshness reservation-freshness--<%= refresh.status %>">
  <span class="reservation-freshness__pulse"></span>
  <% if refresh.last_refreshed_at %>
    <span>Reservas atualizadas às <strong><%= l(refresh.last_refreshed_at, format: '%H:%M') %></strong>
      (<%= time_ago_in_words(refresh.last_refreshed_at) %> atrás)</span>
    <span class="reservation-freshness__sep">·</span>
    <span>próxima às <strong><%= l(refresh.next_refresh_at, format: '%H:%M') %></strong></span>
  <% else %>
    <span>Reservas ainda não foram atualizadas.</span>
  <% end %>
  <% if refresh.status == 'running' %>
    <span class="reservation-freshness__badge"><i class="fas fa-sync fa-spin me-1"></i>atualizando</span>
  <% elsif refresh.status.in?(%w[error partial]) && refresh.message.present? %>
    <span class="reservation-freshness__badge reservation-freshness__badge--warn" title="<%= refresh.message %>">
      <i class="fas fa-triangle-exclamation me-1"></i><%= refresh.status == 'error' ? 'falhou' : 'parcial' %>
    </span>
  <% end %>
</div>
```

> `l(..., format: '%H:%M')` com locale `en` funciona com string de formato. Se o fuso exibido estiver errado, confira `config.time_zone`.

- [ ] **Step 4: Update the items section of the form**

Em `app/views/b2b_orders/_form.html.erb`:

1. Logo abaixo do `<div class="d-flex gap-2 mb-3 ...">` dos botões (antes da `<table ... id="itemsTable">`):
```erb
      <%= render 'stock_reservations/freshness', refresh: StockReservationRefresh.for(:b2b) %>
```
2. Cabeçalho: trocar `<th>Estoque Correios B2B</th>` por `<th>Estoque · Reservado · Disponível</th>`.
3. Trocar a linha `<span class="text-muted-custom d-block mt-2">...Estoque exibido é só informativo — não bloqueia o envio.</span>` por:
```erb
      <div id="stockEnforcementNotice" class="stock-enforcement-notice d-none" role="status"></div>
      <span class="text-muted-custom d-block mt-2"><i class="fas fa-info-circle me-1"></i>Disponível = estoque Correios B2B − itens reservados na fila do Tiny. Não dá para adicionar item sem disponível nem pedir acima dele.</span>
```
4. Na tag `<table class="orders-table" id="itemsTable">`, acrescentar o atributo que liga o bloqueio na tela (só enquanto o pedido não foi para o Tiny — mesma regra do servidor, Task 3):
```erb
      <table class="orders-table" id="itemsTable" data-enforce-stock="<%= @b2b_order.tiny_reference_id.blank? && !@b2b_order.cancelado? %>">
```
5. Substituir a `queueStockFetch` inteira (e o `stockCache[sku] = ...` dentro dela) por este bloco. Regras: linhas **novas** (seletor, planilha) são removidas se o disponível for ≤ 0 e têm a quantidade reduzida ao disponível; linhas que **já estavam** no pedido ao abrir a edição só ficam em vermelho (o servidor barra); digitar acima do disponível volta para o máximo. SKU com erro no Correios não é bloqueado.
```javascript
  var enforceStock = document.getElementById('itemsTable').dataset.enforceStock === 'true';
  var reservationsUrl = <%= raw (current_user.can_access_screen?('stock_reservations_b2b') ? b2b_stock_reservations_path.to_json : 'null') %>;

  function blocksSku(data) {
    return enforceStock && data && data.status !== 'error';
  }

  // Aviso animado listando o que o bloqueio mudou (linhas removidas / quantidades reduzidas).
  var noticeLines = [];
  var noticeTimer;
  function notifyStockChange(message) {
    var box = document.getElementById('stockEnforcementNotice');
    noticeLines.push(message);
    box.innerHTML = '<i class="fas fa-lock me-2"></i><div>' + noticeLines.map(function (l) { return '<div>' + l + '</div>'; }).join('') + '</div>';
    box.classList.remove('d-none');
    box.classList.remove('stock-enforcement-notice--in');
    void box.offsetWidth; // reinicia a animação
    box.classList.add('stock-enforcement-notice--in');
    clearTimeout(noticeTimer);
    noticeTimer = setTimeout(function () { noticeLines = []; box.classList.add('d-none'); }, 12000);
  }

  function reservedText(data) {
    return data.reserved > 0 ? ' · ' + data.reserved + ' reservados na fila' : '';
  }

  // Pinta "estoque − reservado = disponível" e destaca a linha se a quantidade passar do disponível.
  function paintStockCell(cell) {
    var data = stockCache[cell.dataset.sku];
    if (!data) return;
    var row = cell.closest('tr');
    if (data.status === 'error') {
      cell.innerHTML = '<span class="text-muted-custom">indisponível</span>';
      row.classList.remove('item-row--short');
      return;
    }
    var qtyInput = row.querySelector('input[name$="[quantity]"]');
    var requested = qtyInput ? parseInt(qtyInput.value, 10) || 0 : 0;
    if (qtyInput && blocksSku(data)) qtyInput.max = Math.max(data.quantity, 0);
    var short = requested > data.quantity;
    var reserved = data.reserved > 0 && reservationsUrl
      ? '<a href="' + reservationsUrl + '?sku=' + encodeURIComponent(cell.dataset.sku) + '" class="stock-breakdown__reserved" target="_blank">' + data.reserved + '</a>'
      : '<span class="stock-breakdown__reserved">' + data.reserved + '</span>';
    cell.innerHTML =
      '<span class="stock-breakdown">' +
        '<span>' + data.stock + '</span><span class="stock-breakdown__op">−</span>' + reserved +
        '<span class="stock-breakdown__op">=</span><strong class="stock-breakdown__available stock-breakdown__available--' + data.status + '">' + data.quantity + '</strong>' +
      '</span>' +
      (short ? '<span class="stock-breakdown__alert"><i class="fas fa-lock me-1"></i>faltam ' + (requested - data.quantity) + reservedText(data) + '</span>' : '');
    row.classList.toggle('item-row--short', short);
  }

  // Linha recém-adicionada (seletor/planilha): some se não há disponível; quantidade cai para o disponível.
  function enforceNewRow(cell) {
    var data = stockCache[cell.dataset.sku];
    if (!blocksSku(data)) return;
    var row = cell.closest('tr');
    var qtyInput = row.querySelector('input[name$="[quantity]"]');
    var requested = qtyInput ? parseInt(qtyInput.value, 10) || 0 : 0;
    if (data.quantity <= 0) {
      row.classList.add('item-row--leaving');
      setTimeout(function () { row.remove(); }, 350);
      notifyStockChange('<strong>' + cell.dataset.sku + '</strong> não foi adicionado: 0 disponível' + reservedText(data) + '.');
    } else if (requested > data.quantity) {
      qtyInput.value = data.quantity;
      paintStockCell(cell);
      notifyStockChange('<strong>' + cell.dataset.sku + '</strong>: quantidade reduzida de ' + requested + ' para ' + data.quantity + ' (disponível' + reservedText(data) + ').');
    }
  }

  function loadStock(sku) {
    if (Object.prototype.hasOwnProperty.call(stockCache, sku)) return Promise.resolve(stockCache[sku]);
    return fetch('<%= product_stock_b2b_orders_path %>?sku=' + encodeURIComponent(sku))
      .then(function (r) { return r.json(); })
      .then(function (data) {
        stockCache[sku] = { quantity: data.quantity, stock: data.stock, reserved: data.reserved, status: data.status };
        return stockCache[sku];
      });
  }

  var queueStockFetch = makeQueue(function (cell) {
    var sku = cell.dataset.sku;
    if (!sku) return Promise.resolve();

    return loadStock(sku)
      .then(function () {
        paintStockCell(cell);
        if (cell.dataset.newRow === 'true') enforceNewRow(cell);
      })
      .catch(function () { cell.textContent = 'erro'; });
  }, 200);

  // Digitar acima do disponível volta para o máximo.
  document.getElementById('itemsTableBody').addEventListener('input', function (e) {
    if (!e.target.matches('input[name$="[quantity]"]')) return;
    var cell = e.target.closest('tr').querySelector('.item-stock-cell');
    if (!cell) return;
    var data = stockCache[cell.dataset.sku];
    var typed = parseInt(e.target.value, 10) || 0;
    if (blocksSku(data) && typed > data.quantity && data.quantity > 0) {
      e.target.value = data.quantity;
      notifyStockChange('<strong>' + cell.dataset.sku + '</strong>: máximo disponível é ' + data.quantity + reservedText(data) + '.');
    }
    paintStockCell(cell);
  });
```
6. Em `addItemRow`, marcar a célula de estoque como linha nova e já consultar o estoque (antes só era consultado ao clicar em "Atualizar estoque"; agora precisa, para bloquear). Trocar a célula:
```javascript
      '<td class="item-stock-cell" data-sku="' + (sku || '') + '" data-new-row="true">-</td>' +
```
e, no fim da função, depois de `if (!imageUrl) queueImageFetch(...)`:
```javascript
    queueStockFetch(row.querySelector('.item-stock-cell'));
```
Atualizar o comentário acima de `checkAllItemsStock` ("Itens adicionados depois ... só têm o estoque consultado quando o usuário clicar em ...") para: "Itens adicionados depois (planilha, modal) têm o estoque consultado na hora, pela mesma fila com pausa, para o bloqueio por disponível."

7. Seletor de produtos — variante sem disponível fica desabilitada:

Em `renderPickerResults`, ao criar o checkbox da variante, desabilitar até o estoque chegar:
```javascript
        cb.className = 'form-check-input picker-variant-cb';
        cb.disabled = enforceStock;
```
No `productCb` ("selecionar todas"), mexer só nas habilitadas — trocar o listener por:
```javascript
      productCb.addEventListener('change', function () {
        variantCheckboxes.forEach(function (cb, idx) {
          if (cb.disabled) return;
          cb.checked = productCb.checked;
          setVariantSelected(cb, product.variants[idx]);
        });
        updatePickerFooter();
      });
```
e, no listener de cada variante, trocar `productCb.checked = variantCheckboxes.every(...)` por:
```javascript
          var enabled = variantCheckboxes.filter(function (c) { return !c.disabled; });
          productCb.checked = enabled.length > 0 && enabled.every(function (c) { return c.checked; });
```
Substituir `renderPickerStock` por:
```javascript
  function renderPickerStock(cell, cached) {
    var cb = cell.closest('tr').querySelector('.picker-variant-cb');
    var blocked = blocksSku(cached) && cached.quantity <= 0;
    if (cb) {
      cb.disabled = blocked;
      if (blocked) cb.checked = false;
    }
    cell.closest('tr').classList.toggle('picker-variant--blocked', blocked);
    if (cached.status === 'error') {
      cell.innerHTML = '<span class="text-muted-custom">-</span>';
    } else if (cached.quantity > 0) {
      cell.innerHTML = '<span>' + cached.quantity + '</span>' + (cached.reserved > 0 ? '<small class="d-block text-muted-custom">' + cached.reserved + ' reservados</small>' : '');
    } else {
      cell.innerHTML = '<span class="text-warning"><i class="fas fa-lock me-1"></i>0 disponível</span>' + (cached.reserved > 0 ? '<small class="d-block text-muted-custom">' + cached.reserved + ' reservados na fila</small>' : '');
    }
  }
```
Em `fetchPickerStock`, trocar `stockCache[sku] = { quantity: data.quantity, status: data.status };` por:
```javascript
          stockCache[sku] = { quantity: data.quantity, stock: data.stock, reserved: data.reserved, status: data.status };
```
e, no `.catch`, liberar o checkbox (Correios fora não bloqueia):
```javascript
          var cb = cell.closest('tr').querySelector('.picker-variant-cb');
          if (cb) cb.disabled = false;
```

> `reservationsUrl` depende da rota da Task 5 e da chave de tela `stock_reservations_b2b` (Task 5).

- [ ] **Step 5: Styles (conteúdo canônico do início do arquivo — criado na Task 5; aqui só confira)**

`app/assets/stylesheets/admin/pages/_stock_reservations.scss` (início):
```scss
@import 'admin/variables';

@keyframes reservation-pulse {
  0%   { box-shadow: 0 0 0 0 rgba($accent-green-light, 0.6); }
  70%  { box-shadow: 0 0 0 8px rgba($accent-green-light, 0); }
  100% { box-shadow: 0 0 0 0 rgba($accent-green-light, 0); }
}

@keyframes reservation-rise {
  from { opacity: 0; transform: translateY(6px); }
  to   { opacity: 1; transform: translateY(0); }
}

@keyframes reservation-shake {
  0%, 100% { transform: translateX(0); }
  25%      { transform: translateX(-2px); }
  75%      { transform: translateX(2px); }
}

.reservation-freshness {
  display: inline-flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 0.5rem;
  margin-bottom: 0.75rem;
  padding: 0.4rem 0.9rem;
  border: 1px solid $border-muted;
  border-radius: $radius-pill;
  background: linear-gradient(90deg, rgba($accent-blue, 0.12), rgba($accent-green, 0.08));
  color: $text-secondary;
  font-size: 0.85rem;
  animation: reservation-rise 0.4s ease-out;

  strong { color: $text-primary; }

  &__pulse {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: $accent-green-light;
    animation: reservation-pulse 2s infinite;
  }

  &--error &__pulse, &--partial &__pulse { background: $accent-yellow; animation: none; }
  &--running &__pulse { background: $accent-blue-light; }

  &__sep { color: $text-faint; }

  &__badge {
    padding: 0.1rem 0.55rem;
    border-radius: $radius-pill;
    background: rgba($accent-blue, 0.2);
    color: $accent-blue-lighter;
    font-size: 0.75rem;

    &--warn { background: rgba($accent-yellow, 0.15); color: $accent-yellow; }
  }
}

.stock-breakdown {
  display: inline-flex;
  align-items: baseline;
  gap: 0.3rem;
  font-variant-numeric: tabular-nums;

  &__op { color: $text-faint; }
  &__reserved { color: $accent-yellow; text-decoration: none; }
  a.stock-breakdown__reserved:hover { text-decoration: underline; }

  &__available {
    padding: 0 0.4rem;
    border-radius: $radius-sm;
    &--high { color: $accent-green-light; background: rgba($accent-green, 0.15); }
    &--low  { color: $accent-yellow; background: rgba($accent-yellow, 0.12); }
    &--out  { color: $accent-red-light; background: rgba($accent-red, 0.15); }
  }

  &__alert {
    display: block;
    margin-top: 0.2rem;
    color: $accent-red-light;
    font-size: 0.75rem;
    animation: reservation-shake 0.3s ease-in-out 2;
  }
}

.item-row--short td {
  background: rgba($accent-red, 0.08);
  transition: background 0.3s ease;
}

.item-row--leaving {
  opacity: 0;
  transform: translateX(16px);
  transition: opacity 0.35s ease, transform 0.35s ease;
}

.picker-variant--blocked td { opacity: 0.55; }

.stock-enforcement-notice {
  display: flex;
  align-items: flex-start;
  margin: 0.75rem 0 0;
  padding: 0.6rem 0.9rem;
  border: 1px solid rgba($accent-yellow, 0.4);
  border-left: 4px solid $accent-yellow;
  border-radius: $radius-md;
  background: rgba($accent-yellow, 0.08);
  color: $text-secondary;
  font-size: 0.85rem;

  i { color: $accent-yellow; margin-top: 0.2rem; }
  &--in { animation: reservation-rise 0.35s ease-out; }
}
```

(O import em `admin.scss` já foi feito na Task 5.)

- [ ] **Step 6: Run tests**

Run: `... bin/rails test test/controllers/b2b_orders_stock_reservation_test.rb test/controllers/b2b_orders_controller_test.rb`
Expected: PASS.

- [ ] **Step 7: Visual check**

Subir `RAILS_ENV=test bin/rails s` no banco de teste (ver memória: compilar `Rails.application.assets['admin.css']`, reiniciar), abrir o formulário de pedido B2B com um item reservado e renderizar com `qlmanage -t` para conferir a célula "3 − 2 = 1" e o banner de atualização. O comportamento em JS (variante desabilitada no seletor com disponível 0, linha da planilha removida, quantidade limitada ao digitar) não tem teste automatizado (não há Chrome); conferir lendo o JS com cuidado e, se possível, abrindo a página num navegador.

---

### Task 5: Telas de Reserva B2B e B2C

**Files:**
- Create: `app/controllers/stock_reservations_controller.rb`
- Create: `app/views/stock_reservations/index.html.erb`
- Modify: `config/routes.rb`
- Modify: `app/models/screen.rb`
- Modify: `app/views/layouts/partials/_sidebar.html.erb` (grupos Correios B2C :163 e Correios B2B :232)
- Create: `app/assets/stylesheets/admin/pages/_stock_reservations.scss` + import em `admin.scss` (a Task 4 acrescenta os estilos do formulário)
- Test: `test/controllers/stock_reservations_controller_test.rb`, `test/models/screen_test.rb` (adicionar)

**Interfaces:**
- Consumes: `StockReservation`, `StockReservationRefresh.for` (Task 1); `StockReservationRefreshJob.perform_later(account)`, `StockReservationRefresher::ACCOUNTS` (Task 2); partial `stock_reservations/_freshness` — criado nesta task com o conteúdo da Task 4, Step 3 (a Task 4 só o reutiliza).
- Produces: rotas `b2b_stock_reservations_path`, `b2c_stock_reservations_path`, `refresh_stock_reservations_path(account:)`; chaves de tela `stock_reservations_b2b`, `stock_reservations_b2c`.

- [ ] **Step 1: Write the failing tests**

`test/controllers/stock_reservations_controller_test.rb`:
```ruby
require 'test_helper'

class StockReservationsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  def setup
    @admin = User.create!(name: 'Admin Reservas', email: 'admin_reservas@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    Product.create!(sku: 'LEG-A', shopify_product_name: 'Legging A')
    StockReservation.create!(account: :b2b, tiny_order_id: '1', tiny_order_number: '1001', customer_name: 'Loja X', sku: 'LEG-A', quantity: 2)
    StockReservation.create!(account: :b2b, tiny_order_id: '2', tiny_order_number: '1002', customer_name: 'Loja Y', sku: 'LEG-A', quantity: 2)
    StockReservation.create!(account: :b2b, tiny_order_id: '2', tiny_order_number: '1002', customer_name: 'Loja Y', sku: 'TOP-B', quantity: 1)
    StockReservation.create!(account: :b2c, tiny_order_id: '9', tiny_order_number: '9009', customer_name: 'Cliente Z', sku: 'LEG-A', quantity: 7)
  end

  test 'b2b screen groups reservations by sku with totals and orders' do
    sign_in @admin
    get b2b_stock_reservations_path

    assert_response :success
    assert_select '.reservation-kpi', text: /2\s*pedidos/
    assert_select '.reservation-kpi', text: /2\s*SKUs/
    assert_select '.reservation-kpi', text: /5\s*unidades/
    assert_select '.reservation-sku', count: 2
    assert_select '.reservation-sku', text: /LEG-A.*Legging A/m
    assert_select '.reservation-order', text: /1001.*Loja X/m
    assert_no_match(/9009/, response.body)
  end

  test 'b2c screen shows only b2c reservations' do
    sign_in @admin
    get b2c_stock_reservations_path

    assert_match(/9009/, response.body)
    assert_no_match(/1001/, response.body)
  end

  test 'sku filter narrows the list' do
    sign_in @admin
    get b2b_stock_reservations_path(sku: 'top')

    assert_select '.reservation-sku', count: 1
    assert_select '.reservation-sku', text: /TOP-B/
  end

  test 'refresh enqueues the job for the account' do
    sign_in @admin

    assert_enqueued_with(job: StockReservationRefreshJob, args: ['b2c']) do
      post refresh_stock_reservations_path(account: 'b2c')
    end
    assert_redirected_to b2c_stock_reservations_path
  end

  test 'refresh rejects an unknown account' do
    sign_in @admin
    post refresh_stock_reservations_path(account: 'xyz')
    assert_response :not_found
  end

  test 'each screen needs its own permission' do
    profile = Profile.create!(name: 'So Reserva B2B')
    profile.update!(screen_keys: ['stock_reservations_b2b'])
    user = User.create!(name: 'Reserva B2B', email: 'reserva_b2b@example.com', password: 'password123')
    user.profiles << profile
    sign_in user

    get b2b_stock_reservations_path
    assert_response :success

    get b2c_stock_reservations_path
    assert_redirected_to root_path

    post refresh_stock_reservations_path(account: 'b2c')
    assert_redirected_to root_path
  end

  test 'sidebar shows the reservation link to a user with only that permission' do
    profile = Profile.create!(name: 'So Reserva B2C')
    profile.update!(screen_keys: ['stock_reservations_b2c'])
    user = User.create!(name: 'Reserva B2C', email: 'reserva_b2c@example.com', password: 'password123')
    user.profiles << profile
    sign_in user

    get b2c_stock_reservations_path

    assert_select "a[href='#{b2c_stock_reservations_path}']"
    assert_select "a[href='#{b2b_stock_reservations_path}']", count: 0
    assert_select "a[href='#{order_correios_create_dashboard_index_path}']", count: 0
  end
end
```

Adicionar em `test/models/screen_test.rb`:
```ruby
  test 'stock reservation screens belong to their Correios groups' do
    assert_includes Screen::GROUPS['Correios B2B'], :stock_reservations_b2b
    assert_includes Screen::GROUPS['Correios B2C'], :stock_reservations_b2c
    assert_equal 'Reservas de Estoque B2B', Screen.label(:stock_reservations_b2b)
    assert_equal 'Reservas de Estoque B2C', Screen.label(:stock_reservations_b2c)
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `... bin/rails test test/controllers/stock_reservations_controller_test.rb test/models/screen_test.rb`
Expected: ERROR `undefined local variable or method 'b2b_stock_reservations_path'` e falha no screen_test.

- [ ] **Step 3: Screens, routes and controller**

`app/models/screen.rb` — em `DEFINITIONS`, após `dashboard_correios_b2b:`:
```ruby
    stock_reservations_b2c: 'Reservas de Estoque B2C',
    stock_reservations_b2b: 'Reservas de Estoque B2B',
```
e em `GROUPS`:
```ruby
    'Correios B2C' => %i[dashboard_correios stock_reservations_b2c],
    'Correios B2B' => %i[dashboard_correios_b2b stock_reservations_b2b],
```

`config/routes.rb` — junto dos outros `resources` do painel (fora do bloco `dashboard`):
```ruby
  resources :stock_reservations, only: [] do
    collection do
      get :b2b
      get :b2c
      post :refresh
    end
  end
```

`app/controllers/stock_reservations_controller.rb`:
```ruby
# Reservas de estoque: itens dos pedidos que estão na fila do Tiny (B2B = Tiny2, B2C = Tiny3).
class StockReservationsController < ApplicationController
  guard_screen :stock_reservations_b2b, only: :b2b
  guard_screen :stock_reservations_b2c, only: :b2c
  before_action :set_refresh_account, only: :refresh

  def b2b = render_account('b2b')
  def b2c = render_account('b2c')

  def refresh
    StockReservationRefreshJob.perform_later(@account)
    redirect_to account_path(@account), notice: 'Atualização das reservas iniciada. A página recarrega sozinha quando terminar.'
  end

  private

  def set_refresh_account
    @account = params[:account].to_s
    return head :not_found unless StockReservationRefresher::ACCOUNTS.key?(@account)

    authorize_screen!("stock_reservations_#{@account}")
  end

  def account_path(account)
    account == 'b2b' ? b2b_stock_reservations_path : b2c_stock_reservations_path
  end

  def render_account(account)
    @account = account
    @refresh = StockReservationRefresh.for(account)
    @sku_query = params[:sku].to_s.strip.upcase

    scope = StockReservation.where(account:)
    scope = scope.where('sku LIKE ?', "%#{StockReservation.sanitize_sql_like(@sku_query)}%") if @sku_query.present?
    reservations = scope.order(:sku, :order_date, :tiny_order_number).to_a

    @groups = reservations.group_by(&:sku)
    @product_names = Product.where(sku: @groups.keys).pluck(:sku, :shopify_product_name)
                            .to_h { |sku, name| [sku.to_s.upcase, name] }
    @kpis = { orders: reservations.map(&:tiny_order_id).uniq.size, skus: @groups.size,
              units: reservations.sum(&:quantity).ceil }
    render :index
  end
end
```

> `authorize_screen!` é privado em `ApplicationController` e faz `redirect_to` — chamado de dentro de um `before_action`, o redirect interrompe a action. Confirme que ele não faz `return` antes do redirect para quem tem acesso (linhas 23-26).

- [ ] **Step 4: View**

`app/views/stock_reservations/index.html.erb`:
```erb
<% label = @account == 'b2b' ? 'B2B' : 'B2C' %>
<% content_for :title, "Reservas de Estoque #{label}" %>

<div class="users-container reservations-page">
  <div class="page-header">
    <div class="header-left">
      <h1 class="page-title"><i class="fas fa-lock me-2"></i>Reservas de Estoque <%= label %></h1>
      <p class="page-subtitle">
        Itens de pedidos na fila do Tiny (<%= @account == 'b2b' ? 'Tiny2' : 'Tiny3' %>, preparando envio) que ainda não viraram pedido no Correios Log.
        <% if @account == 'b2b' %>Esses itens saem do disponível na criação de pedidos B2B.<% else %>Tela informativa: o Shopify já desconta as próprias vendas.<% end %>
      </p>
    </div>
    <div class="header-actions">
      <%= button_to refresh_stock_reservations_path(account: @account), method: :post, class: 'btn-export', form: { class: 'd-inline' } do %>
        <i class="fas fa-sync me-2"></i>Atualizar agora
      <% end %>
    </div>
  </div>

  <%= render 'stock_reservations/freshness', refresh: @refresh %>

  <div class="reservation-kpis">
    <div class="reservation-kpi"><i class="fas fa-receipt"></i><strong data-count="<%= @kpis[:orders] %>"><%= @kpis[:orders] %></strong> pedidos</div>
    <div class="reservation-kpi"><i class="fas fa-barcode"></i><strong data-count="<%= @kpis[:skus] %>"><%= @kpis[:skus] %></strong> SKUs</div>
    <div class="reservation-kpi"><i class="fas fa-boxes"></i><strong data-count="<%= @kpis[:units] %>"><%= @kpis[:units] %></strong> unidades</div>
  </div>

  <div class="table-card">
    <%= form_with url: (@account == 'b2b' ? b2b_stock_reservations_path : b2c_stock_reservations_path), method: :get, local: true, class: 'd-flex gap-2 flex-wrap px-3 pb-3' do %>
      <%= text_field_tag :sku, @sku_query, placeholder: 'Buscar SKU', class: 'field-input', style: 'max-width: 260px;' %>
      <button type="submit" class="btn-back"><i class="fas fa-search me-1"></i>Buscar</button>
      <% if @sku_query.present? %>
        <%= link_to 'Limpar', (@account == 'b2b' ? b2b_stock_reservations_path : b2c_stock_reservations_path), class: 'btn-back' %>
      <% end %>
    <% end %>

    <% if @groups.any? %>
      <div class="table-responsive">
        <table class="orders-table">
          <thead>
            <tr><th>SKU</th><th>Produto</th><th class="text-end">Reservado</th><th class="text-end">Pedidos</th><th></th></tr>
          </thead>
          <% @groups.each_with_index do |(sku, rows), index| %>
            <tbody class="reservation-sku" style="animation-delay: <%= [index, 20].min * 30 %>ms">
              <tr class="reservation-sku__row" data-bs-toggle="collapse" data-bs-target="#reservation-<%= index %>">
                <td class="text-main"><%= sku %></td>
                <td class="text-muted-custom"><%= @product_names[sku] || '—' %></td>
                <td class="text-end"><span class="reservation-qty"><%= rows.sum(&:quantity).ceil %></span></td>
                <td class="text-end"><%= rows.map(&:tiny_order_id).uniq.size %></td>
                <td class="text-end"><i class="fas fa-chevron-down reservation-sku__chevron"></i></td>
              </tr>
              <tr class="collapse <%= 'show' if @sku_query.present? %>" id="reservation-<%= index %>">
                <td colspan="5" class="reservation-orders">
                  <% rows.each do |row| %>
                    <div class="reservation-order">
                      <span class="reservation-order__number">#<%= row.tiny_order_number.presence || row.tiny_order_id %></span>
                      <span><%= row.customer_name %></span>
                      <span class="text-muted-custom"><%= row.order_date&.strftime('%d/%m/%Y') %></span>
                      <span class="reservation-order__qty"><%= row.quantity.to_i == row.quantity ? row.quantity.to_i : row.quantity %> un.</span>
                    </div>
                  <% end %>
                </td>
              </tr>
            </tbody>
          <% end %>
        </table>
      </div>
    <% else %>
      <div class="text-center text-muted-custom py-5 reservation-empty">
        <i class="fas fa-check-circle fa-2x mb-2"></i>
        <div><%= @sku_query.present? ? "Nenhuma reserva para \"#{@sku_query}\"." : 'Nenhum item reservado na fila.' %></div>
      </div>
    <% end %>
  </div>
</div>

<script>
  (function () {
    // KPIs sobem de 0 até o valor (efeito de contagem).
    document.querySelectorAll('.reservation-kpi strong[data-count]').forEach(function (el) {
      var target = parseInt(el.dataset.count, 10) || 0;
      var start = performance.now();
      function tick(now) {
        var progress = Math.min((now - start) / 700, 1);
        el.textContent = Math.round(target * (1 - Math.pow(1 - progress, 3)));
        if (progress < 1) requestAnimationFrame(tick);
      }
      requestAnimationFrame(tick);
    });

    // Enquanto atualiza, recarrega sozinha.
    <% if @refresh.status == 'running' %>
      setTimeout(function () { window.location.reload(); }, 15000);
    <% end %>
  })();
</script>
```

> Se `button_to` com bloco não aceitar `form:` nesta versão, use `form_with url: ..., method: :post` com um `<button>`.

- [ ] **Step 5: Styles for the screen**

Criar `app/assets/stylesheets/admin/pages/_stock_reservations.scss` com o bloco da Task 4, Step 5 (import, keyframes, `.reservation-freshness`, `.stock-breakdown`, `.item-row--short`) seguido deste bloco, e adicionar `@import 'admin/pages/stock_reservations';` em `app/assets/stylesheets/admin.scss` após `@import 'admin/pages/internal_transfers';`. Criar também o partial `app/views/stock_reservations/_freshness.html.erb` com o conteúdo da Task 4, Step 3.
```scss
.reservation-kpis {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
  gap: 1rem;
  margin-bottom: 1.25rem;
}

.reservation-kpi {
  display: flex;
  align-items: baseline;
  gap: 0.5rem;
  padding: 1rem 1.25rem;
  border: 1px solid $border-default;
  border-radius: $radius-lg;
  background: $bg-surface;
  color: $text-muted;
  animation: reservation-rise 0.5s ease-out both;
  transition: transform 0.2s ease, border-color 0.2s ease;

  &:hover { transform: translateY(-2px); border-color: $accent-blue; }
  &:nth-child(2) { animation-delay: 80ms; }
  &:nth-child(3) { animation-delay: 160ms; }

  i { color: $accent-blue-light; }
  strong { font-size: 1.6rem; color: $text-primary; font-variant-numeric: tabular-nums; }
}

.reservation-sku {
  animation: reservation-rise 0.35s ease-out both;

  &__row { cursor: pointer; transition: background 0.2s ease; }
  &__row:hover td { background: $bg-elevated; }
  &__chevron { color: $text-faint; transition: transform 0.25s ease; }
  &__row[aria-expanded='true'] &__chevron { transform: rotate(180deg); }
}

.reservation-qty {
  padding: 0.1rem 0.6rem;
  border-radius: $radius-pill;
  background: rgba($accent-yellow, 0.15);
  color: $accent-yellow;
  font-weight: 600;
}

.reservation-orders { background: $bg-canvas; }

.reservation-order {
  display: grid;
  grid-template-columns: 110px 1fr 110px 80px;
  gap: 0.75rem;
  padding: 0.35rem 0.5rem;
  border-bottom: 1px dashed $border-default;
  animation: reservation-rise 0.3s ease-out both;

  &:last-child { border-bottom: none; }
  &__number { color: $accent-blue-light; font-weight: 600; }
  &__qty { text-align: right; color: $text-primary; }
}

.reservation-empty i { color: $accent-green-light; animation: reservation-rise 0.6s ease-out; }

@media (max-width: 576px) {
  .reservation-order { grid-template-columns: 1fr 1fr; }
}
```

- [ ] **Step 6: Sidebar**

Em `app/views/layouts/partials/_sidebar.html.erb`:

Grupo **Correios B2C** (:163): trocar a condição do grupo por
```erb
        <% if current_user&.can_access_screen?('dashboard_correios') || current_user&.can_access_screen?('stock_reservations_b2c') %>
```
e, dentro de `<div class="dropdown-content">`, envolver todos os links existentes em `<% if current_user&.can_access_screen?('dashboard_correios') %> ... <% end %>`; depois desse `end`, adicionar:
```erb
                <% if current_user&.can_access_screen?('stock_reservations_b2c') %>
                  <%= link_to b2c_stock_reservations_path, class: "dropdown-link #{'active' if current_page?(b2c_stock_reservations_path)}" do %>
                    <i class="fas fa-lock"></i>
                    <span>Reservas de Estoque</span>
                  <% end %>
                <% end %>
```

Grupo **Correios B2B** (:232): o mesmo, com `dashboard_correios_b2b`, `stock_reservations_b2b` e `b2b_stock_reservations_path`.

- [ ] **Step 7: Run tests**

Run: `... bin/rails test test/controllers/stock_reservations_controller_test.rb test/models/screen_test.rb test/controllers/sidebar_test.rb test/controllers/profiles_controller_test.rb`
Expected: PASS.

- [ ] **Step 8: Visual check**

Com o servidor de teste, semear algumas reservas no banco de teste (e recriar o banco depois — ver memória), abrir `/stock_reservations/b2b` e renderizar com `qlmanage -t`: KPIs animados, linhas expansíveis, banner de atualização.

---

### Task 6: Verificação final e agendamento

**Files:** nenhum novo.

- [ ] **Step 1: Suite completa**

Run: `TEST_DATABASE_URL=... PARALLEL_WORKERS=1 bin/rails test`
Expected: apenas as 7 falhas preexistentes (home_controller, tickets/add_message, ticket_notifier, ticket_overdue_job).

- [ ] **Step 2: Conferir que nada tocou o banco de development**

Run: `git status` — só arquivos do plano; nenhum `db:migrate` foi executado fora do MySQL temporário.

- [ ] **Step 3: Passar ao usuário os passos de produção**

1. Deploy (o `release` do Heroku roda `db:migrate`).
2. Heroku Scheduler → Add Job → `bundle exec rake stock_reservations:refresh`, a cada 10 minutos.
3. Rodar uma vez na mão para popular: `heroku run bundle exec rake stock_reservations:refresh`.
4. Liberar as telas "Reservas de Estoque B2B/B2C" nos perfis que precisarem (admin já vê).
