# Pedidos B2B — status do Tiny, campos do formulário e desconto por item — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rework the Pedidos B2B (`B2bOrder`) feature so the listing shows the real Tiny order status (aberto/aprovado/preparando envio/faturado/pronto para envio/enviado/não entregue/dados incompletos/cancelado), the creation form has the extra fields (Natureza da operação, Número, Vendedor, Lista de preço, endereço de entrega diferente), and each item line accepts a R$ discount.

**Architecture:** `B2bOrder#status` becomes an enum mirroring Tiny's own `situacao` vocabulary. Saving a pedido now auto-enqueues `TransmitB2bOrderJob` (no manual "Transmitir" click); a new periodic `SyncB2bOrdersStatusJob`, wired into the existing `MakeCsvDataJob` cron entrypoint, pulls the real `situacao` from Tiny's `pedido.obter.php` for `sale`-kind orders (stock transfers create a nota fiscal in Tiny, not a pedido, so they're out of this sync's scope) and updates the local status. New columns carry the new form fields and the per-item discount; the discount is netted into the unit price sent to Tiny.

**Tech Stack:** Ruby on Rails 7.2, MySQL, Minitest + WebMock, Sidekiq (ActiveJob), Sass (Sprockets), vanilla JS (no framework) for the form's dynamic behavior.

**Spec:** `docs/superpowers/specs/2026-09-18-b2b-orders-status-and-form-redesign-design.md`

## Global Constraints

- Discount is a fixed R$ value per item (not a percentage).
- Status changes are driven by syncing from Tiny — never set manually by staff in the UI.
- "Natureza da operação" is the existing `kind` field, only re-skinned as a `select` (`Atacado` / `Transferência de Estoque`).
- "Vendedor" is a free-text field (`salesperson_name`), not tied to `User`.
- Index status tabs show only "Todos", "Aberto" and "Aprovado" by default; the remaining 7 statuses are revealed by clicking "mais" (no page reload).
- "Previsto", "Data limite de despacho" columns and the "Entregue" tab are explicitly out of scope.
- Changing the price list to "Transferência" only affects items added to the table *after* the change — it never recalculates rows already present.
- Follow existing code style: no comments unless documenting a non-obvious constraint, Portuguese user-facing strings, the `field-input`/`form-grid`/`form-col-N`/`table-card`/`status-pill`/`action-btn`/`btn-export` CSS class family already used across `app/views/b2b_orders`.

---

## Task 1: Desconto fixo por item (`B2bOrderItem#discount`)

**Files:**
- Create: `db/migrate/20260918120000_add_discount_to_b2b_order_items.rb`
- Modify: `app/models/b2b_order_item.rb`
- Modify: `app/models/b2b_order.rb`
- Test: `test/models/b2b_order_item_test.rb` (new file)
- Test: `test/models/b2b_order_test.rb`

**Interfaces:**
- Produces: `B2bOrderItem#discount` (decimal, default 0), `B2bOrderItem#line_total` (Float — `(price - discount).clamp(0, ...) * quantity`), `B2bOrder#total` (Float — sum of `b2b_order_items.line_total`).

- [ ] **Step 1: Write the migration**

```ruby
# db/migrate/20260918120000_add_discount_to_b2b_order_items.rb
class AddDiscountToB2bOrderItems < ActiveRecord::Migration[7.2]
  def change
    add_column :b2b_order_items, :discount, :decimal, precision: 10, scale: 2, null: false, default: 0
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `bin/rails db:migrate`
Expected: `b2b_order_items` gets a `discount` column; `db/schema.rb` version bumps and shows the new column.

- [ ] **Step 3: Write the failing tests**

Create `test/models/b2b_order_item_test.rb`:

```ruby
require 'test_helper'

class B2bOrderItemTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(name: 'Teste Item', email: 'teste_item@example.com', password: 'password123')
    @client = Client.create!(responsible_name: 'Cliente Item')
    @order = B2bOrder.create!(kind: :sale, user: @user, client: @client)
  end

  test 'discount defaults to zero' do
    item = @order.b2b_order_items.create!(sku: 'SKU1', quantity: 1, price: 10)
    assert_equal 0, item.discount
  end

  test 'discount cannot be negative' do
    item = @order.b2b_order_items.build(sku: 'SKU1', quantity: 1, price: 10, discount: -1)
    refute item.valid?
    assert_includes item.errors[:discount], 'deve ser maior ou igual a 0'
  end

  test 'line_total subtracts the discount before multiplying by quantity' do
    item = @order.b2b_order_items.create!(sku: 'SKU1', quantity: 3, price: 10, discount: 2)
    assert_equal 24.0, item.line_total
  end

  test 'line_total never goes negative even if discount exceeds price' do
    item = @order.b2b_order_items.create!(sku: 'SKU1', quantity: 2, price: 5, discount: 20)
    assert_equal 0.0, item.line_total
  end
end
```

Add to `test/models/b2b_order_test.rb` (inside the existing class, after the last test):

```ruby
  test 'total sums the line totals of all items' do
    order = B2bOrder.new(kind: :sale, user: @user, client: @client)
    order.b2b_order_items.build(sku: 'A', quantity: 2, price: 10, discount: 1)
    order.b2b_order_items.build(sku: 'B', quantity: 1, price: 5, discount: 0)
    order.save!
    assert_equal 23.0, order.total
  end
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `bin/rails test test/models/b2b_order_item_test.rb test/models/b2b_order_test.rb -n "/discount|line_total|total sums/"`
Expected: FAIL — `discount`/`line_total`/`total` undefined.

- [ ] **Step 5: Implement**

`app/models/b2b_order_item.rb`:

```ruby
class B2bOrderItem < ApplicationRecord
  belongs_to :b2b_order

  validates :sku, presence: true
  validates :quantity, numericality: { greater_than: 0 }
  validates :price, numericality: { greater_than_or_equal_to: 0 }
  validates :discount, numericality: { greater_than_or_equal_to: 0 }

  def product
    Product.find_by(sku: sku)
  end

  def line_total
    [price.to_f - discount.to_f, 0].max * quantity.to_i
  end
end
```

Add to `app/models/b2b_order.rb` (inside the class, e.g. right after `transmittable?` — that method is reworked in Task 3, so just add this one near it):

```ruby
  def total
    b2b_order_items.sum(&:line_total)
  end
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bin/rails test test/models/b2b_order_item_test.rb test/models/b2b_order_test.rb`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add db/migrate/20260918120000_add_discount_to_b2b_order_items.rb db/schema.rb app/models/b2b_order_item.rb app/models/b2b_order.rb test/models/b2b_order_item_test.rb test/models/b2b_order_test.rb
git commit -m "Add fixed R$ discount per b2b_order_item and B2bOrder#total"
```

---

## Task 2: Lista de preço e endereço de entrega diferente (schema + validações)

**Files:**
- Create: `db/migrate/20260918120100_add_form_fields_to_b2b_orders.rb`
- Modify: `app/models/b2b_order.rb`
- Test: `test/models/b2b_order_test.rb`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `B2bOrder#salesperson_name` (string), `B2bOrder#price_list` enum (`standard`/`transfer`, default `standard`), `B2bOrder#different_shipping_address` (boolean, default false), `B2bOrder#shipping_street/number/complement/neighbourhood/city/state/zip` (strings). Later tasks (5, 8) read these.

- [ ] **Step 1: Write the migration**

```ruby
# db/migrate/20260918120100_add_form_fields_to_b2b_orders.rb
class AddFormFieldsToB2bOrders < ActiveRecord::Migration[7.2]
  def change
    add_column :b2b_orders, :salesperson_name, :string
    add_column :b2b_orders, :price_list, :integer, null: false, default: 0
    add_column :b2b_orders, :different_shipping_address, :boolean, null: false, default: false
    add_column :b2b_orders, :shipping_street, :string
    add_column :b2b_orders, :shipping_number, :string
    add_column :b2b_orders, :shipping_complement, :string
    add_column :b2b_orders, :shipping_neighbourhood, :string
    add_column :b2b_orders, :shipping_city, :string
    add_column :b2b_orders, :shipping_state, :string
    add_column :b2b_orders, :shipping_zip, :string
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `bin/rails db:migrate`
Expected: new columns appear on `b2b_orders` in `db/schema.rb`.

- [ ] **Step 3: Write the failing tests**

Add to `test/models/b2b_order_test.rb`:

```ruby
  test 'price_list defaults to standard' do
    order = B2bOrder.new(kind: :sale, user: @user, client: @client)
    assert order.standard?
  end

  test 'different_shipping_address requires the shipping address fields' do
    order = B2bOrder.new(kind: :sale, user: @user, client: @client, different_shipping_address: true)
    order.b2b_order_items.build(sku: 'A', quantity: 1, price: 10)
    refute order.valid?
    assert_includes order.errors[:shipping_street], 'não pode ficar em branco'
    assert_includes order.errors[:shipping_zip], 'não pode ficar em branco'
  end

  test 'different_shipping_address is valid once all fields are filled' do
    order = B2bOrder.new(
      kind: :sale, user: @user, client: @client, different_shipping_address: true,
      shipping_street: 'Rua X', shipping_number: '10', shipping_neighbourhood: 'Centro',
      shipping_city: 'BH', shipping_state: 'MG', shipping_zip: '30000-000'
    )
    order.b2b_order_items.build(sku: 'A', quantity: 1, price: 10)
    assert order.valid?
  end
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `bin/rails test test/models/b2b_order_test.rb -n "/price_list|shipping_address/"`
Expected: FAIL — `standard?`/`different_shipping_address` undefined.

- [ ] **Step 5: Implement**

In `app/models/b2b_order.rb`, add the enum next to the existing ones and the conditional validation next to the existing `validates`:

```ruby
  enum :price_list, { standard: 0, transfer: 1 }
```

```ruby
  validates :shipping_street, :shipping_number, :shipping_neighbourhood, :shipping_city,
            :shipping_state, :shipping_zip, presence: true, if: :different_shipping_address?
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bin/rails test test/models/b2b_order_test.rb`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add db/migrate/20260918120100_add_form_fields_to_b2b_orders.rb db/schema.rb app/models/b2b_order.rb test/models/b2b_order_test.rb
git commit -m "Add salesperson_name, price_list and shipping address fields to b2b_orders"
```

---

## Task 3: Status do pedido vira o vocabulário do Tiny + envio automático ao salvar

This is the one behavioral change everything else in this plan depends on, so it's a single task even though it touches several files — splitting it would leave the test suite red between commits.

**Files:**
- Create: `db/migrate/20260918120200_remap_b2b_orders_status_values.rb`
- Modify: `app/models/b2b_order.rb`
- Modify: `app/jobs/transmit_b2b_order_job.rb`
- Modify: `app/controllers/b2b_orders_controller.rb`
- Modify: `test/models/b2b_order_test.rb`
- Create: `test/jobs/transmit_b2b_order_job_test.rb`
- Modify: `test/controllers/b2b_orders_controller_test.rb`
- Modify: `test/services/b2b_tiny_service_test.rb`
- Modify: `test/models/carrier_test.rb`
- Modify: `test/controllers/carriers_controller_test.rb`
- Modify: `test/controllers/transfer_locations_controller_test.rb`

**Interfaces:**
- Consumes: `B2bOrder#total` (Task 1, unaffected here).
- Produces: `B2bOrder::STATUS_LABELS` (Hash, string key → PT-BR label), `B2bOrder::PRIMARY_STATUSES` / `B2bOrder::SECONDARY_STATUSES` (arrays of string status keys), `B2bOrder::TINY_SITUATION_MAP` (Hash, Tiny `situacao` string → our status key string), `B2bOrder#resendable?` (Boolean). Tasks 4 and 7 depend on all four constants and on `resendable?`.

- [ ] **Step 1: Write the migration**

```ruby
# db/migrate/20260918120200_remap_b2b_orders_status_values.rb
class RemapB2bOrdersStatusValues < ActiveRecord::Migration[7.2]
  def up
    execute <<~SQL.squish
      UPDATE b2b_orders SET status = CASE status
        WHEN 0 THEN 0
        WHEN 1 THEN 0
        WHEN 2 THEN 0
        WHEN 3 THEN 7
        ELSE status
      END
    SQL
  end

  def down
    execute <<~SQL.squish
      UPDATE b2b_orders SET status = CASE status
        WHEN 7 THEN 3
        ELSE 0
      END
    SQL
  end
end
```

This has no schema-shape effect (the `status` column stays an integer), so it doesn't change `db/schema.rb` beyond the version line — the real "migration" here is data (old `draft`/`saved`/`transmitted` → `aberto`, old `error` → `dados_incompletos`).

- [ ] **Step 2: Run the migration**

Run: `bin/rails db:migrate`
Expected: version bump in `db/schema.rb`, no column changes.

- [ ] **Step 3: Update the model tests to the new enum first (red)**

Replace the whole `test/models/b2b_order_test.rb` file with:

```ruby
require 'test_helper'

class B2bOrderTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(name: 'Teste B2B', email: 'teste_b2b@example.com', password: 'password123')
    @client = Client.create!(responsible_name: 'Cliente Teste')
    @location = TransferLocation.create!(
      name: 'CD Teste', registration: '25.405.327/0001-74',
      street: 'Rua Teste', number: '100', neighbourhood: 'Centro',
      city: 'Belo Horizonte', state: 'MG', zip: '30000-000'
    )
  end

  test 'status defaults to aberto' do
    order = B2bOrder.new(kind: :sale, user: @user, client: @client)
    assert order.aberto?
  end

  test 'sale order requires a client' do
    order = B2bOrder.new(kind: :sale, user: @user)
    order.b2b_order_items.build(sku: 'ABC', quantity: 1, price: 10)
    refute order.valid?
    assert_includes order.errors[:client], 'não pode ficar em branco'
  end

  test 'stock_transfer order requires a transfer_location' do
    order = B2bOrder.new(kind: :stock_transfer, user: @user)
    order.b2b_order_items.build(sku: 'ABC', quantity: 1, price: 10)
    refute order.valid?
    assert_includes order.errors[:transfer_location], 'não pode ficar em branco'
  end

  test 'order requires at least one item' do
    order = B2bOrder.new(kind: :sale, user: @user, client: @client)
    refute order.valid?
    assert_includes order.errors[:base], 'Pedido precisa ter pelo menos um item'
  end

  test 'a fully filled sale order is valid' do
    order = B2bOrder.new(kind: :sale, user: @user, client: @client)
    order.b2b_order_items.build(sku: 'ABC', name: 'Produto', quantity: 2, price: 10.5)
    assert order.valid?
  end

  test 'resendable? is true only for dados_incompletos without a tiny_reference_id' do
    order = B2bOrder.new(kind: :sale, user: @user, status: :aberto)
    refute order.resendable?

    order.status = :dados_incompletos
    assert order.resendable?

    order.tiny_reference_id = '123'
    refute order.resendable?
  end

  test 'total sums the line totals of all items' do
    order = B2bOrder.new(kind: :sale, user: @user, client: @client)
    order.b2b_order_items.build(sku: 'A', quantity: 2, price: 10, discount: 1)
    order.b2b_order_items.build(sku: 'B', quantity: 1, price: 5, discount: 0)
    order.save!
    assert_equal 23.0, order.total
  end

  test 'price_list defaults to standard' do
    order = B2bOrder.new(kind: :sale, user: @user, client: @client)
    assert order.standard?
  end

  test 'different_shipping_address requires the shipping address fields' do
    order = B2bOrder.new(kind: :sale, user: @user, client: @client, different_shipping_address: true)
    order.b2b_order_items.build(sku: 'A', quantity: 1, price: 10)
    refute order.valid?
    assert_includes order.errors[:shipping_street], 'não pode ficar em branco'
    assert_includes order.errors[:shipping_zip], 'não pode ficar em branco'
  end

  test 'different_shipping_address is valid once all fields are filled' do
    order = B2bOrder.new(
      kind: :sale, user: @user, client: @client, different_shipping_address: true,
      shipping_street: 'Rua X', shipping_number: '10', shipping_neighbourhood: 'Centro',
      shipping_city: 'BH', shipping_state: 'MG', shipping_zip: '30000-000'
    )
    order.b2b_order_items.build(sku: 'A', quantity: 1, price: 10)
    assert order.valid?
  end
end
```

(This folds in the Task 1/2 tests too, since the old `draft`-based tests they were appended to no longer exist in this rewritten file.)

- [ ] **Step 4: Run the tests to verify they fail**

Run: `bin/rails test test/models/b2b_order_test.rb`
Expected: FAIL — `resendable?` undefined, `draft?`/`saved?` no longer referenced so no failures from those, but `aberto?` etc. undefined until Step 5.

- [ ] **Step 5: Implement the model changes**

Replace the enum/validation/method block in `app/models/b2b_order.rb`:

```ruby
class B2bOrder < ApplicationRecord
  belongs_to :client, optional: true
  belongs_to :transfer_location, optional: true
  belongs_to :carrier, optional: true
  belongs_to :user
  has_many :b2b_order_items, dependent: :destroy
  accepts_nested_attributes_for :b2b_order_items, allow_destroy: true, reject_if: :all_blank

  enum :kind, { sale: 0, stock_transfer: 1 }
  enum :status, {
    aberto: 0, aprovado: 1, preparando_envio: 2, faturado: 3,
    pronto_para_envio: 4, enviado: 5, nao_entregue: 6,
    dados_incompletos: 7, cancelado: 8
  }
  enum :price_list, { standard: 0, transfer: 1 }
  enum :freight_paid_by, { shipper: 0, recipient: 1 }

  STATUS_LABELS = {
    'aberto' => 'Aberto', 'aprovado' => 'Aprovado', 'preparando_envio' => 'Preparando Envio',
    'faturado' => 'Faturado', 'pronto_para_envio' => 'Pronto para Envio', 'enviado' => 'Enviado',
    'nao_entregue' => 'Não Entregue', 'dados_incompletos' => 'Dados Incompletos',
    'cancelado' => 'Cancelado'
  }.freeze
  PRIMARY_STATUSES = %w[aberto aprovado].freeze
  SECONDARY_STATUSES = (STATUS_LABELS.keys - PRIMARY_STATUSES).freeze

  TINY_SITUATION_MAP = {
    'Aberto' => 'aberto', 'Aprovado' => 'aprovado', 'Preparando Envio' => 'preparando_envio',
    'Faturado' => 'faturado', 'Pronto para Envio' => 'pronto_para_envio', 'Enviado' => 'enviado',
    'Não Entregue' => 'nao_entregue', 'Cancelado' => 'cancelado',
    'Dados Incompletos' => 'dados_incompletos'
  }.freeze

  validates :client, presence: true, if: :sale?
  validates :transfer_location, presence: true, if: :stock_transfer?
  validates :shipping_street, :shipping_number, :shipping_neighbourhood, :shipping_city,
            :shipping_state, :shipping_zip, presence: true, if: :different_shipping_address?
  validate :must_have_items

  scope :recent, -> { order(created_at: :desc) }

  def resendable?
    dados_incompletos? && tiny_reference_id.blank?
  end

  def total
    b2b_order_items.sum(&:line_total)
  end

  private

  def must_have_items
    errors.add(:base, 'Pedido precisa ter pelo menos um item') if b2b_order_items.empty?
  end
end
```

This removes `transmittable?` (replaced by `resendable?`) and the old `unless: :draft?`/`unless: :draft?` conditions — presence of client/transfer_location and items is now always required, since there's no more local-only draft state.

- [ ] **Step 6: Run the model tests to verify they pass**

Run: `bin/rails test test/models/b2b_order_test.rb`
Expected: PASS

- [ ] **Step 7: Write the failing test for `TransmitB2bOrderJob`'s new status transitions**

Create `test/jobs/transmit_b2b_order_job_test.rb`:

```ruby
require 'test_helper'
require 'webmock/minitest'

class TransmitB2bOrderJobTest < ActiveSupport::TestCase
  def setup
    ENV['TOKEN_TINY2_PRODUCTION'] = 'fake-token'
    @user = User.create!(name: 'Teste Transmit', email: 'teste_transmit@example.com', password: 'password123')
    @client = Client.create!(responsible_name: 'Cliente Transmit')
  end

  test 'sets status to aberto and stores the tiny reference on success' do
    order = B2bOrder.create!(kind: :sale, user: @user, client: @client)
    order.b2b_order_items.create!(sku: 'SKU1', quantity: 1, price: 10)

    stub_request(:post, 'https://api.tiny.com.br/api2/pedido.incluir.php')
      .to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '111', numero: '222' } } } }.to_json)

    TransmitB2bOrderJob.perform_now(order.id)

    order.reload
    assert order.aberto?
    assert_equal '111', order.tiny_reference_id
    assert_equal '222', order.tiny_reference_number
  end

  test 'sets status to dados_incompletos and stores the error message on failure' do
    order = B2bOrder.create!(kind: :sale, user: @user, client: @client)
    order.b2b_order_items.create!(sku: 'SKU1', quantity: 1, price: 10)

    stub_request(:post, 'https://api.tiny.com.br/api2/pedido.incluir.php')
      .to_return(body: { retorno: { status: 'Erro', erros: { erro: 'CPF/CNPJ inválido' } } }.to_json)

    TransmitB2bOrderJob.perform_now(order.id)

    order.reload
    assert order.dados_incompletos?
    assert_equal 'CPF/CNPJ inválido', order.error_message
  end
end
```

- [ ] **Step 8: Run the test to verify it fails**

Run: `bin/rails test test/jobs/transmit_b2b_order_job_test.rb`
Expected: FAIL — the job still sets `status: :transmitted`/`status: :error`, which no longer exist as enum keys, so `perform_now` raises `ArgumentError`.

- [ ] **Step 9: Update `TransmitB2bOrderJob`**

```ruby
# app/jobs/transmit_b2b_order_job.rb
class TransmitB2bOrderJob < ActiveJob::Base
  queue_as :default

  def perform(b2b_order_id)
    order = B2bOrder.find(b2b_order_id)
    service = B2bTinyService.new

    result = order.sale? ? service.create_sale_order(order) : service.create_stock_transfer(order)

    if result[:success]
      order.update!(status: :aberto, tiny_reference_id: result[:tiny_reference_id], tiny_reference_number: result[:tiny_reference_number])
    else
      order.update!(status: :dados_incompletos, error_message: result[:error])
    end
  end
end
```

- [ ] **Step 10: Run the test to verify it passes**

Run: `bin/rails test test/jobs/transmit_b2b_order_job_test.rb`
Expected: PASS

- [ ] **Step 11: Update the controller — auto-transmit on create, resend instead of transmit**

In `app/controllers/b2b_orders_controller.rb`, replace `create`, `transmit` and `b2b_order_params`:

```ruby
  def create
    @b2b_order = B2bOrder.new(b2b_order_params)
    @b2b_order.user = current_user

    if @b2b_order.save
      TransmitB2bOrderJob.perform_later(@b2b_order.id)
      redirect_to b2b_orders_path, notice: 'Pedido salvo e enviado para o Tiny.'
    else
      render :new, status: :unprocessable_entity
    end
  end
```

```ruby
  def transmit
    unless @b2b_order.resendable?
      redirect_to b2b_orders_path, alert: 'Este pedido não pode ser reenviado.'
      return
    end

    TransmitB2bOrderJob.perform_later(@b2b_order.id)
    redirect_to b2b_orders_path, notice: 'Pedido reenviado para o Tiny.'
  end
```

```ruby
  def b2b_order_params
    params.require(:b2b_order).permit(
      :kind, :client_id, :transfer_location_id, :carrier_id, :carrier_name,
      :carrier_shipping_method, :freight_paid_by, :freight_value, :notes,
      :salesperson_name, :price_list, :different_shipping_address,
      :shipping_street, :shipping_number, :shipping_complement, :shipping_neighbourhood,
      :shipping_city, :shipping_state, :shipping_zip,
      b2b_order_items_attributes: [:id, :sku, :name, :quantity, :price, :discount, :_destroy]
    )
  end
```

`:status` is intentionally dropped from the permitted params — status is now only ever set by `TransmitB2bOrderJob` and the sync job (Task 4), never directly from the form.

- [ ] **Step 12: Update the controller tests**

In `test/controllers/b2b_orders_controller_test.rb`, replace the two `create`/`transmit` tests:

```ruby
  test 'admin can create a sale order with client and items, which auto-enqueues transmission' do
    sign_in @admin

    assert_enqueued_with(job: TransmitB2bOrderJob) do
      assert_difference 'B2bOrder.count', 1 do
        post b2b_orders_path, params: { b2b_order: {
          kind: 'sale', client_id: @client.id,
          b2b_order_items_attributes: [{ sku: 'SKU1', name: 'Produto', quantity: 2, price: 10 }]
        } }
      end
    end
    order = B2bOrder.last
    assert order.aberto?
    assert_equal 1, order.b2b_order_items.count
  end

  test 'creating without items re-renders with errors' do
    sign_in @admin

    assert_no_difference 'B2bOrder.count' do
      post b2b_orders_path, params: { b2b_order: { kind: 'sale', client_id: @client.id } }
    end
    assert_response :unprocessable_entity
  end

  test 'transmit resends only when the order is resendable' do
    sign_in @admin
    order = B2bOrder.create!(kind: :sale, user: @admin, client: @client, status: :aberto)
    order.b2b_order_items.create!(sku: 'SKU1', quantity: 1, price: 1)

    assert_no_enqueued_jobs only: TransmitB2bOrderJob do
      post transmit_b2b_order_path(order)
    end
    assert_redirected_to b2b_orders_path

    order.update!(status: :dados_incompletos)

    assert_enqueued_with(job: TransmitB2bOrderJob, args: [order.id]) do
      post transmit_b2b_order_path(order)
    end
  end
```

Remove the old `'admin can create a draft without items or client'` test entirely — there's no draft state anymore.

- [ ] **Step 13: Fix incidental B2bOrder fixtures in unrelated test files**

These files create a bare `B2bOrder` only to exercise a `dependent: :restrict_with_error` destroy check on `Carrier`/`TransferLocation` — they now need a valid (client + item, or transfer_location + item) order since `status: :draft` no longer exists.

`test/models/carrier_test.rb`, inside `'cannot be destroyed while it has b2b_orders'`:

```ruby
    user = User.create!(name: 'Teste Carrier', email: 'teste_carrier@example.com', password: 'password123')
    client = Client.create!(responsible_name: 'Cliente Carrier')
    order = B2bOrder.create!(kind: :sale, carrier: carrier, user: user, client: client)
    order.b2b_order_items.create!(sku: 'SKU1', quantity: 1, price: 1)
```

(replaces the old `B2bOrder.create!(kind: :sale, status: :draft, carrier: carrier, user: user)` line)

`test/controllers/carriers_controller_test.rb`, inside `'destroy is blocked when the carrier still has b2b_orders'`:

```ruby
    client = Client.create!(responsible_name: 'Cliente Carrier Destroy')
    order = B2bOrder.create!(kind: :sale, carrier: carrier, user: @admin, client: client)
    order.b2b_order_items.create!(sku: 'SKU1', quantity: 1, price: 1)
```

(replaces the old `B2bOrder.create!(kind: :sale, status: :draft, carrier: carrier, user: @admin)` line)

`test/controllers/transfer_locations_controller_test.rb`, inside `'destroy is blocked when the location still has b2b_orders'`:

```ruby
    order = B2bOrder.create!(kind: :stock_transfer, transfer_location: location, user: @admin)
    order.b2b_order_items.create!(sku: 'SKU1', quantity: 1, price: 1)
```

(replaces the old `B2bOrder.create!(kind: :stock_transfer, status: :draft, transfer_location: location, user: @admin)` line)

- [ ] **Step 14: Remove `status: :saved` from `test/services/b2b_tiny_service_test.rb`**

Every `B2bOrder.create!(kind: ..., status: :saved, ...)` call in that file becomes `B2bOrder.create!(kind: ..., ...)` (just drop the `status: :saved,` fragment — the new default `aberto` is valid for these already-fully-formed orders). There are 5 occurrences.

- [ ] **Step 15: Run the full test suite for this task**

Run: `bin/rails test test/models/b2b_order_test.rb test/jobs/transmit_b2b_order_job_test.rb test/controllers/b2b_orders_controller_test.rb test/services/b2b_tiny_service_test.rb test/models/carrier_test.rb test/controllers/carriers_controller_test.rb test/controllers/transfer_locations_controller_test.rb`
Expected: PASS (all green)

- [ ] **Step 16: Commit**

```bash
git add db/migrate/20260918120200_remap_b2b_orders_status_values.rb db/schema.rb \
  app/models/b2b_order.rb app/jobs/transmit_b2b_order_job.rb app/controllers/b2b_orders_controller.rb \
  test/models/b2b_order_test.rb test/jobs/transmit_b2b_order_job_test.rb test/controllers/b2b_orders_controller_test.rb test/services/b2b_tiny_service_test.rb \
  test/models/carrier_test.rb test/controllers/carriers_controller_test.rb test/controllers/transfer_locations_controller_test.rb
git commit -m "Rework B2bOrder status into Tiny's situação vocabulary; auto-transmit on save"
```

---

## Task 4: Sincronização periódica do status com o Tiny

**Files:**
- Create: `db/migrate/20260918120300_add_tracking_code_to_b2b_orders.rb`
- Modify: `app/services/b2b_tiny_service.rb`
- Create: `app/jobs/sync_b2b_orders_status_job.rb`
- Modify: `app/jobs/make_csv_data_job.rb`
- Modify: `test/services/b2b_tiny_service_test.rb`
- Create: `test/jobs/sync_b2b_orders_status_job_test.rb`

**Interfaces:**
- Consumes: `B2bOrder::TINY_SITUATION_MAP` (Task 3), `B2bOrder.sale` (existing `kind` enum scope).
- Produces: `B2bTinyService#order_status(tiny_reference_id)` → `{ situacao: String, tracking_code: String_or_nil }` or `nil` on failure/non-OK. `SyncB2bOrdersStatusJob` (no public interface beyond `.perform_now`/`.perform_later`, used by Task 7's manual QA only, not by other tasks).

- [ ] **Step 1: Write the migration**

```ruby
# db/migrate/20260918120300_add_tracking_code_to_b2b_orders.rb
class AddTrackingCodeToB2bOrders < ActiveRecord::Migration[7.2]
  def change
    add_column :b2b_orders, :tracking_code, :string
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `bin/rails db:migrate`
Expected: `tracking_code` column added to `b2b_orders`.

- [ ] **Step 3: Write the failing service test**

Add to `test/services/b2b_tiny_service_test.rb`:

```ruby
  test 'order_status returns the situacao and tracking code from Tiny' do
    stub_request(:get, 'https://api.tiny.com.br/api2/pedido.obter.php')
      .with(query: hash_including({ 'id' => '111' }))
      .to_return(body: { retorno: { status: 'OK', pedido: { situacao: 'Faturado', codigo_rastreamento: 'BR123456789' } } }.to_json)

    result = @service.order_status('111')
    assert_equal 'Faturado', result[:situacao]
    assert_equal 'BR123456789', result[:tracking_code]
  end

  test 'order_status returns nil when Tiny responds with an error' do
    stub_request(:get, 'https://api.tiny.com.br/api2/pedido.obter.php')
      .with(query: hash_including({ 'id' => '111' }))
      .to_return(body: { retorno: { status: 'Erro' } }.to_json)

    assert_nil @service.order_status('111')
  end
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `bin/rails test test/services/b2b_tiny_service_test.rb -n "/order_status/"`
Expected: FAIL — `order_status` undefined.

- [ ] **Step 5: Implement `order_status`**

In `app/services/b2b_tiny_service.rb`, add a public method (right after `create_carrier_contact`, before `private`):

```ruby
  def order_status(tiny_reference_id)
    response = HTTParty.get("#{BASE_URL}/pedido.obter.php",
                             query: { token: @token, formato: 'json', id: tiny_reference_id })
    retorno = JSON.parse(response.body).with_indifferent_access[:retorno]
    return nil unless retorno[:status] == 'OK'

    pedido = retorno[:pedido]
    { situacao: pedido[:situacao], tracking_code: pedido[:codigo_rastreamento].presence }
  rescue StandardError => e
    Rails.logger.error "B2bTinyService#order_status exception: #{e.message}"
    nil
  end
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `bin/rails test test/services/b2b_tiny_service_test.rb`
Expected: PASS

- [ ] **Step 7: Write the failing job test**

Create `test/jobs/sync_b2b_orders_status_job_test.rb`:

```ruby
require 'test_helper'
require 'webmock/minitest'

class SyncB2bOrdersStatusJobTest < ActiveSupport::TestCase
  def setup
    ENV['TOKEN_TINY2_PRODUCTION'] = 'fake-token'
    @user = User.create!(name: 'Teste Sync', email: 'teste_sync@example.com', password: 'password123')
    @client = Client.create!(responsible_name: 'Cliente Sync')
  end

  test 'updates the status of sale orders that already have a tiny_reference_id' do
    order = B2bOrder.create!(kind: :sale, user: @user, client: @client, status: :aberto, tiny_reference_id: '111')
    order.b2b_order_items.create!(sku: 'SKU1', quantity: 1, price: 10)

    stub_request(:get, 'https://api.tiny.com.br/api2/pedido.obter.php')
      .with(query: hash_including({ 'id' => '111' }))
      .to_return(body: { retorno: { status: 'OK', pedido: { situacao: 'Faturado', codigo_rastreamento: 'BR1' } } }.to_json)

    SyncB2bOrdersStatusJob.perform_now

    order.reload
    assert order.faturado?
    assert_equal 'BR1', order.tracking_code
  end

  test 'ignores orders without a tiny_reference_id' do
    order = B2bOrder.create!(kind: :sale, user: @user, client: @client, status: :aberto)
    order.b2b_order_items.create!(sku: 'SKU1', quantity: 1, price: 10)

    SyncB2bOrdersStatusJob.perform_now

    assert_not_requested :get, 'https://api.tiny.com.br/api2/pedido.obter.php'
    assert order.reload.aberto?
  end

  test 'ignores stock_transfer orders (they create a nota fiscal in Tiny, not a pedido)' do
    location = TransferLocation.create!(
      name: 'CD Sync', registration: '25.405.327/0001-74', street: 'Rua Sync',
      number: '1', neighbourhood: 'B', city: 'BH', state: 'MG', zip: '30000-000'
    )
    order = B2bOrder.create!(kind: :stock_transfer, user: @user, transfer_location: location, status: :aberto, tiny_reference_id: '222')
    order.b2b_order_items.create!(sku: 'SKU1', quantity: 1, price: 10)

    SyncB2bOrdersStatusJob.perform_now

    assert_not_requested :get, 'https://api.tiny.com.br/api2/pedido.obter.php'
  end
end
```

- [ ] **Step 8: Run the test to verify it fails**

Run: `bin/rails test test/jobs/sync_b2b_orders_status_job_test.rb`
Expected: FAIL — `SyncB2bOrdersStatusJob` undefined.

- [ ] **Step 9: Implement the job**

```ruby
# app/jobs/sync_b2b_orders_status_job.rb
class SyncB2bOrdersStatusJob < ActiveJob::Base
  queue_as :default

  def perform
    service = B2bTinyService.new

    B2bOrder.sale.where.not(tiny_reference_id: [nil, '']).find_each do |order|
      result = service.order_status(order.tiny_reference_id)
      next unless result

      new_status = B2bOrder::TINY_SITUATION_MAP[result[:situacao]]
      next unless new_status

      attrs = { status: new_status }
      attrs[:tracking_code] = result[:tracking_code] if result[:tracking_code].present?
      order.update(attrs)
    end
  end
end
```

- [ ] **Step 10: Run the test to verify it passes**

Run: `bin/rails test test/jobs/sync_b2b_orders_status_job_test.rb`
Expected: PASS

- [ ] **Step 11: Wire the job into the existing cron entrypoint**

In `app/jobs/make_csv_data_job.rb`, add a fourth block inside `perform`, after the "Atualização dos pedidos" one:

```ruby
    motor = find_or_create_motor('Atualização de status dos pedidos B2B')
    log_job('SyncB2bOrdersStatusJob') { run_job_and_update_motor(motor) { SyncB2bOrdersStatusJob.perform_now } }
```

- [ ] **Step 12: Run the full task test suite**

Run: `bin/rails test test/services/b2b_tiny_service_test.rb test/jobs/sync_b2b_orders_status_job_test.rb`
Expected: PASS

- [ ] **Step 13: Commit**

```bash
git add db/migrate/20260918120300_add_tracking_code_to_b2b_orders.rb db/schema.rb \
  app/services/b2b_tiny_service.rb app/jobs/sync_b2b_orders_status_job.rb app/jobs/make_csv_data_job.rb \
  test/services/b2b_tiny_service_test.rb test/jobs/sync_b2b_orders_status_job_test.rb
git commit -m "Sync B2bOrder status from Tiny's pedido.obter.php on the existing cron entrypoint"
```

---

## Task 5: Desconto líquido e endereço de entrega no payload do Tiny

**Files:**
- Modify: `app/services/b2b_tiny_service.rb`
- Modify: `test/services/b2b_tiny_service_test.rb`

**Interfaces:**
- Consumes: `B2bOrderItem#discount` (Task 1), `B2bOrder#different_shipping_address?`/`#shipping_*` (Task 2).
- Produces: nothing new consumed elsewhere — this only changes the outbound Tiny payload.

- [ ] **Step 1: Write the failing tests**

Add to `test/services/b2b_tiny_service_test.rb`:

```ruby
  test 'create_sale_order sends the unit price net of the item discount' do
    order = B2bOrder.create!(kind: :sale, user: @user, client: @client)
    order.b2b_order_items.create!(sku: 'SKU1', name: 'Produto 1', quantity: 2, price: 10, discount: 2)

    stub_request(:post, 'https://api.tiny.com.br/api2/pedido.incluir.php')
      .with { |req| JSON.parse(req.body)['pedido'].include?('"valor_unitario":8.0') }
      .to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '1', numero: '2' } } } }.to_json)

    result = @service.create_sale_order(order)
    assert result[:success]
  end

  test 'create_sale_order includes endereco_entrega when the shipping address differs' do
    order = B2bOrder.create!(
      kind: :sale, user: @user, client: @client, different_shipping_address: true,
      shipping_street: 'Rua Entrega', shipping_number: '50', shipping_neighbourhood: 'Bairro E',
      shipping_city: 'Rio de Janeiro', shipping_state: 'RJ', shipping_zip: '20000-000'
    )
    order.b2b_order_items.create!(sku: 'SKU1', quantity: 1, price: 10)

    stub_request(:post, 'https://api.tiny.com.br/api2/pedido.incluir.php')
      .with { |req| JSON.parse(req.body)['pedido'].include?('"endereco_entrega"') && JSON.parse(req.body)['pedido'].include?('"cep":"20000-000"') }
      .to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '1', numero: '2' } } } }.to_json)

    result = @service.create_sale_order(order)
    assert result[:success]
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/services/b2b_tiny_service_test.rb -n "/net of the item discount|endereco_entrega/"`
Expected: FAIL — payload still sends the raw price and never includes `endereco_entrega`.

- [ ] **Step 3: Implement**

In `app/services/b2b_tiny_service.rb`, replace `build_pedido`:

```ruby
  def build_pedido(b2b_order)
    client = b2b_order.client

    pedido = {
      situacao: 'aberto',
      data_pedido: b2b_order.created_at.strftime('%d/%m/%Y'),
      itens: b2b_order.b2b_order_items.map do |i|
        { item: { codigo: i.sku, descricao: i.name, unidade: 'UN', quantidade: i.quantity,
                   valor_unitario: (i.price.to_f - i.discount.to_f) } }
      end,
      cliente: {
        nome: client.display_name,
        tipo_pessoa: client.registration.present? ? 'J' : 'F',
        cpf_cnpj: client.registration.presence || '',
        ie: client.state_registration.presence || '',
        endereco: client.street.presence || '',
        numero: client.number.presence || '',
        bairro: client.neighbourhood.presence || '',
        cidade: client.city.presence || '',
        uf: client.state.presence || '',
        cep: client.zip.presence || ''
      },
      forma_envio: 'T',
      nome_transportador: b2b_order.carrier&.name || b2b_order.carrier_name,
      forma_frete: b2b_order.carrier_shipping_method,
      frete_por_conta: b2b_order.shipper? ? 'R' : 'D',
      valor_frete: b2b_order.freight_value.to_f,
      obs: b2b_order.notes.presence || "Pedido B2B ##{b2b_order.id}"
    }

    if b2b_order.different_shipping_address?
      pedido[:endereco_entrega] = {
        nome_destinatario: client.display_name,
        endereco: b2b_order.shipping_street.presence || '',
        numero: b2b_order.shipping_number.presence || '',
        complemento: b2b_order.shipping_complement.presence || '',
        bairro: b2b_order.shipping_neighbourhood.presence || '',
        cidade: b2b_order.shipping_city.presence || '',
        uf: b2b_order.shipping_state.presence || '',
        cep: b2b_order.shipping_zip.presence || ''
      }
    end

    pedido
  end
```

And in `build_nota_fiscal`, change the items line:

```ruby
    items = b2b_order.b2b_order_items.map do |i|
      { codigo: i.sku, descricao: i.name, unidade: 'UN', quantidade: i.quantity.to_s,
        valor_unitario: format('%.2f', i.price.to_f - i.discount.to_f), tipo: 'P', cfop: '5152' }
    end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/services/b2b_tiny_service_test.rb`
Expected: PASS (including the pre-existing tests — `build_pedido`'s shape is otherwise unchanged)

- [ ] **Step 5: Commit**

```bash
git add app/services/b2b_tiny_service.rb test/services/b2b_tiny_service_test.rb
git commit -m "Net item discount into Tiny unit price; send endereco_entrega when shipping address differs"
```

---

## Task 6: Preço normal disponível nos endpoints de busca de produto

**Files:**
- Modify: `app/controllers/b2b_orders_controller.rb`
- Modify: `test/controllers/b2b_orders_controller_test.rb`

**Interfaces:**
- Consumes: `Product#price` (existing string column).
- Produces: `retail_price` (Float) added to the JSON of `search_product`, `product_picker` (per variant) and `parse_items_spreadsheet`. Task 8's JS reads this field.

- [ ] **Step 1: Write the failing tests**

Add to `test/controllers/b2b_orders_controller_test.rb`:

```ruby
  test 'search_product also returns the plain retail price alongside the suggested one' do
    sign_in @admin
    Product.create!(sku: 'SKU-RET', shopify_product_name: 'Produto Retail', price: '100')

    get search_product_b2b_orders_path, params: { query: 'SKU-RET' }
    json = JSON.parse(response.body)

    product_json = json['products'].first
    assert_equal 100.0, product_json['retail_price']
    assert_equal 40.0, product_json['suggested_price']
  end

  test 'parse_items_spreadsheet also returns the plain retail price' do
    sign_in @admin
    Product.create!(sku: 'SKU-RET-CSV', shopify_product_name: 'Produto Retail CSV', price: '50')

    csv_content = "SKU,Quantidade\nSKU-RET-CSV,1\n"
    file = Rack::Test::UploadedFile.new(StringIO.new(csv_content), 'text/csv', original_filename: 'items.csv')

    post parse_items_spreadsheet_b2b_orders_path, params: { file: file }
    json = JSON.parse(response.body)

    assert_equal 50.0, json['items'].first['retail_price']
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/controllers/b2b_orders_controller_test.rb -n "/retail price/"`
Expected: FAIL — `retail_price` key missing from the JSON.

- [ ] **Step 3: Implement**

In `app/controllers/b2b_orders_controller.rb`:

`parse_items_spreadsheet`'s item hash:

```ruby
      { sku: sku, name: product&.shopify_product_name, quantity: quantity,
        suggested_price: suggested_price_for(product),
        retail_price: product&.price.to_f,
        image_url: product ? image_url_for(product) : nil }
```

`search_product`'s render:

```ruby
    render json: { success: true, products: products.map { |p| { id: p.id, sku: p.sku, name: p.shopify_product_name, image_url: image_url_for(p), suggested_price: suggested_price_for(p), retail_price: p.price.to_f } } }
```

`product_picker`'s variant hash:

```ruby
          variants: variants.map do |v|
            {
              id: v.id,
              sku: v.sku,
              option: v.option1.presence || v.sku,
              price: suggested_price_for(v),
              retail_price: v.price.to_f
            }
          end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/controllers/b2b_orders_controller_test.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/controllers/b2b_orders_controller.rb test/controllers/b2b_orders_controller_test.rb
git commit -m "Return the plain retail price alongside the suggested price when searching products"
```

---

## Task 7: Tela index — status do Tiny, busca, novas colunas

**Files:**
- Modify: `app/controllers/b2b_orders_controller.rb`
- Modify: `app/views/b2b_orders/index.html.erb`
- Create: `app/assets/stylesheets/admin/pages/_b2b_orders.scss`
- Modify: `app/assets/stylesheets/admin.scss`
- Modify: `test/controllers/b2b_orders_controller_test.rb`

**Interfaces:**
- Consumes: `B2bOrder::STATUS_LABELS`/`PRIMARY_STATUSES`/`SECONDARY_STATUSES` (Task 3), `B2bOrder#total` (Task 1), `B2bOrder#resendable?` (Task 3), `tracking_code` (Task 4).
- Produces: `@b2b_orders`, `@status_counts` (Hash, status key string → count) for the view.

- [ ] **Step 1: Write the failing controller tests**

Add to `test/controllers/b2b_orders_controller_test.rb`:

```ruby
  test 'index counts orders per status regardless of the active status filter' do
    sign_in @admin
    aberto = B2bOrder.create!(kind: :sale, user: @admin, client: @client, status: :aberto)
    aberto.b2b_order_items.create!(sku: 'SKU1', quantity: 1, price: 1)
    aprovado = B2bOrder.create!(kind: :sale, user: @admin, client: @client, status: :aprovado)
    aprovado.b2b_order_items.create!(sku: 'SKU2', quantity: 1, price: 1)

    get b2b_orders_path(status: 'aberto')

    # hrefs are unique per status (e.g. "status=aberto" vs "status=aprovado"),
    # so scoping the count assertion to each tab's own link avoids matching
    # the wrong tab's count pill.
    assert_select "a[href*='status=aberto']", text: /1/
    assert_select "a[href*='status=aprovado']", text: /1/
    assert_select 'tbody tr', count: 1
  end

  test 'index searches by client name' do
    sign_in @admin
    other_client = Client.create!(responsible_name: 'Outro Cliente Completamente Diferente')
    match = B2bOrder.create!(kind: :sale, user: @admin, client: @client)
    match.b2b_order_items.create!(sku: 'SKU1', quantity: 1, price: 1)
    miss = B2bOrder.create!(kind: :sale, user: @admin, client: other_client)
    miss.b2b_order_items.create!(sku: 'SKU2', quantity: 1, price: 1)

    get b2b_orders_path(q: @client.responsible_name)

    assert_select 'tbody tr', count: 1
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/controllers/b2b_orders_controller_test.rb -n "/index counts|index searches/"`
Expected: FAIL — no status tab links exist yet, `q` param is ignored.

- [ ] **Step 3: Implement the controller `index`**

```ruby
  def index
    scope = B2bOrder.left_joins(:client).includes(:transfer_location, :b2b_order_items).recent
    scope = scope.where(kind: params[:kind]) if params[:kind].present?

    if params[:q].present?
      q = "%#{params[:q]}%"
      scope = scope.where(
        'clients.responsible_name LIKE :q OR clients.business_name LIKE :q OR b2b_orders.tiny_reference_number LIKE :q OR b2b_orders.id = :id',
        q: q, id: params[:q].to_i
      )
    end

    # .recent orders by created_at, which MySQL's only_full_group_by mode
    # rejects mixed with GROUP BY status — drop the ORDER BY for this query.
    @status_counts = scope.reorder(nil).group(:status).count
    @b2b_orders = params[:status].present? ? scope.where(status: params[:status]) : scope
  end
```

- [ ] **Step 4: Rewrite the view**

Replace `app/views/b2b_orders/index.html.erb`:

```erb
<% content_for :title, "Pedidos B2B" %>

<div class="users-container">
  <div class="page-header">
    <div class="header-left">
      <h1 class="page-title"><i class="fas fa-handshake me-2"></i>Pedidos B2B</h1>
      <p class="page-subtitle">Pedidos de venda comum e transferências de estoque</p>
    </div>
    <div class="header-actions">
      <span class="total-badge"><i class="fas fa-list me-1"></i><%= @b2b_orders.size %> pedido(s)</span>
      <%= link_to new_b2b_order_path, class: "btn-export" do %><i class="fas fa-plus me-2"></i>Novo Pedido<% end %>
    </div>
  </div>

  <div class="table-card">
    <div class="table-card-header"><h5 class="table-card-title"><i class="fas fa-list me-2"></i>Lista de Pedidos</h5></div>

    <%= form_with url: b2b_orders_path, method: :get, local: true, class: "d-flex gap-2 flex-wrap px-3 pb-3" do %>
      <input type="text" name="q" value="<%= params[:q] %>" class="field-input" placeholder="Pesquise por cliente ou número..." style="max-width: 320px;">
      <%= select_tag :kind, options_for_select([['Todos tipos', ''], ['Pedido Comum', 'sale'], ['Transferência de Estoque', 'stock_transfer']], params[:kind]), class: 'field-input' %>
      <input type="hidden" name="status" value="<%= params[:status] %>">
      <button type="submit" class="btn-back"><i class="fas fa-search me-1"></i>Buscar</button>
    <% end %>

    <div class="status-tabs px-3 pb-3">
      <%= link_to b2b_orders_path(q: params[:q], kind: params[:kind]), class: "status-tab #{'status-tab--active' if params[:status].blank?}" do %>
        Todos <span class="status-tab-count"><%= @status_counts.values.sum %></span>
      <% end %>
      <% B2bOrder::PRIMARY_STATUSES.each do |status_key| %>
        <%= link_to b2b_orders_path(q: params[:q], kind: params[:kind], status: status_key), class: "status-tab #{'status-tab--active' if params[:status] == status_key}" do %>
          <%= B2bOrder::STATUS_LABELS[status_key] %> <span class="status-tab-count"><%= @status_counts[status_key] || 0 %></span>
        <% end %>
      <% end %>
      <button type="button" id="moreStatusesToggle" class="status-tab status-tab--more">mais <i class="fas fa-caret-down ms-1"></i></button>
      <span id="moreStatuses" style="display: none;">
        <% B2bOrder::SECONDARY_STATUSES.each do |status_key| %>
          <%= link_to b2b_orders_path(q: params[:q], kind: params[:kind], status: status_key), class: "status-tab #{'status-tab--active' if params[:status] == status_key}" do %>
            <%= B2bOrder::STATUS_LABELS[status_key] %> <span class="status-tab-count"><%= @status_counts[status_key] || 0 %></span>
          <% end %>
        <% end %>
      </span>
    </div>

    <% if @b2b_orders.any? %>
      <div class="table-responsive">
        <table class="orders-table">
          <thead>
            <tr>
              <th>Nº</th>
              <th>Data</th>
              <th>Cliente</th>
              <th>CNPJ/CPF</th>
              <th class="text-end">Total</th>
              <th>Nº pedido</th>
              <th>Rastreamento</th>
              <th class="text-center">Status</th>
              <th class="text-end">Ações</th>
            </tr>
          </thead>
          <tbody>
            <% @b2b_orders.each do |order| %>
              <tr>
                <td class="text-main">#<%= order.id %></td>
                <td class="text-muted-custom"><%= order.created_at.strftime('%d/%m/%Y') %></td>
                <td class="text-muted-custom"><%= order.sale? ? order.client&.display_name : order.transfer_location&.name %></td>
                <td class="text-muted-custom"><%= order.sale? ? order.client&.cnpj_formatted : '-' %></td>
                <td class="text-end"><%= number_to_currency(order.total) %></td>
                <td class="text-muted-custom"><%= order.tiny_reference_number.presence || '-' %></td>
                <td class="text-muted-custom"><%= order.tracking_code.presence || '-' %></td>
                <td class="text-center">
                  <span class="status-pill status-pill--<%= order.status %>"><%= B2bOrder::STATUS_LABELS[order.status] %></span>
                </td>
                <td class="text-end">
                  <div class="table-actions">
                    <%= link_to edit_b2b_order_path(order), class: "action-btn action-btn--edit" do %><i class="fas fa-pencil-alt"></i><% end %>
                    <% if order.resendable? %>
                      <%= button_to transmit_b2b_order_path(order), method: :post, class: "action-btn action-btn--edit", form: { data: { turbo_confirm: 'Reenviar este pedido para o Tiny?' } } do %>
                        <i class="fas fa-paper-plane"></i>
                      <% end %>
                    <% end %>
                  </div>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    <% else %>
      <div class="empty-state">
        <i class="fas fa-handshake fa-3x mb-3 d-block"></i>
        <h5>Nenhum pedido cadastrado</h5>
        <%= link_to new_b2b_order_path, class: "btn-export" do %><i class="fas fa-plus me-1"></i>Novo Pedido<% end %>
      </div>
    <% end %>
  </div>
</div>

<% content_for :scripts do %>
<script>
document.addEventListener('DOMContentLoaded', function () {
  var toggle = document.getElementById('moreStatusesToggle');
  var more = document.getElementById('moreStatuses');
  if (toggle) {
    toggle.addEventListener('click', function () {
      more.style.display = more.style.display === 'none' ? '' : 'none';
    });
  }
});
</script>
<% end %>
```

- [ ] **Step 5: Add the status tab / status pill styles**

Create `app/assets/stylesheets/admin/pages/_b2b_orders.scss`:

```scss
@import 'admin/variables';

.status-tabs { display: flex; flex-wrap: wrap; align-items: center; gap: 0.5rem; }

.status-tab {
  display: inline-flex;
  align-items: center;
  gap: 0.35rem;
  padding: 0.4rem 0.85rem;
  border-radius: $radius-md;
  color: $text-muted;
  text-decoration: none;
  font-size: 0.85rem;
  font-weight: 600;
  border: 1px solid transparent;
  background: transparent;
  cursor: pointer;
}
.status-tab:hover { color: $text-primary; background: $bg-elevated; }
.status-tab--active { color: $text-primary; background: $bg-elevated; border-color: $border-muted; }
.status-tab-count { color: $text-faint; font-weight: 400; }
.status-tab--more { border: 1px dashed $border-muted; }

.status-pill--aberto { background: rgba(88, 166, 255, 0.12); color: $accent-blue-light; border: 1px solid $accent-blue; }
.status-pill--aprovado { background: rgba(63, 185, 80, 0.15); color: $accent-green-light; border: 1px solid $accent-green; }
.status-pill--preparando_envio { background: rgba(227, 179, 65, 0.15); color: $accent-yellow; border: 1px solid $accent-yellow-alt; }
.status-pill--faturado { background: rgba(31, 111, 235, 0.15); color: $accent-blue-light; border: 1px solid $accent-blue; }
.status-pill--pronto_para_envio { background: rgba(137, 87, 229, 0.15); color: #b392f0; border: 1px solid #8957e5; }
.status-pill--enviado { background: rgba(63, 185, 80, 0.15); color: $accent-green-light; border: 1px solid $accent-green; }
.status-pill--nao_entregue { background: rgba(248, 81, 73, 0.12); color: $accent-red-light; border: 1px solid $accent-red-light; }
.status-pill--dados_incompletos { background: rgba(218, 54, 51, 0.12); color: $accent-red-soft; border: 1px solid $accent-red; }
.status-pill--cancelado { background: rgba(139, 148, 158, 0.12); color: $text-muted; border: 1px solid $border-muted; }

.form-col-12 { flex: 0 0 100%; }
```

(`.form-col-12` is added here since Task 8 needs a full-width grid cell and `admin/pages/_clients.scss` only goes up to `.form-col-7`.)

In `app/assets/stylesheets/admin.scss`, add the import next to the other `admin/pages/*` ones:

```scss
 @import 'admin/pages/orders';
 @import 'admin/pages/b2b_orders';
 @import 'admin/pages/marketing_tasks';
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bin/rails test test/controllers/b2b_orders_controller_test.rb`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add app/controllers/b2b_orders_controller.rb app/views/b2b_orders/index.html.erb \
  app/assets/stylesheets/admin/pages/_b2b_orders.scss app/assets/stylesheets/admin.scss \
  test/controllers/b2b_orders_controller_test.rb
git commit -m "Redesign b2b_orders index with Tiny status tabs, search and new columns"
```

---

## Task 8: Formulário de criação/edição redesenhado

**Files:**
- Modify: `app/views/b2b_orders/_form.html.erb`
- Modify: `test/controllers/b2b_orders_controller_test.rb`

**Interfaces:**
- Consumes: `B2bOrder#salesperson_name`/`#price_list`/`#different_shipping_address`/`#shipping_*` (Task 2), `B2bOrderItem#discount` (Task 1), `retail_price` in the product search JSON (Task 6).
- Produces: nothing consumed by other tasks — this is the last task in the plan.

- [ ] **Step 1: Write the failing controller test**

Add to `test/controllers/b2b_orders_controller_test.rb`:

```ruby
  test 'admin can create a sale order with the new form fields and a per-item discount' do
    sign_in @admin

    assert_difference 'B2bOrder.count', 1 do
      post b2b_orders_path, params: { b2b_order: {
        kind: 'sale', client_id: @client.id, salesperson_name: 'Fulano', price_list: 'transfer',
        b2b_order_items_attributes: [{ sku: 'SKU1', name: 'Produto', quantity: 2, price: 10, discount: 1 }]
      } }
    end
    order = B2bOrder.last
    assert_equal 'Fulano', order.salesperson_name
    assert order.transfer?
    assert_equal 1.0, order.b2b_order_items.first.discount
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/controllers/b2b_orders_controller_test.rb -n "/new form fields/"`
Expected: FAIL — `salesperson_name`/`price_list` come back blank because the form isn't the thing under test here, but the params are already permitted since Task 3 — this test should actually already pass once run, confirming the controller side; it exists to lock in the params contract the form is about to rely on. If it fails, re-check Task 3 Step 8's `b2b_order_params`.

- [ ] **Step 3: Rewrite the "Dados do Pedido" section of the form**

In `app/views/b2b_orders/_form.html.erb`, replace the whole block from `<div class="form-grid mb-3">` (kind radios) through the closing `</div>` of the `form-section-body` that currently holds Cliente/Local de Destino/Forma de Envio/Transportadora — i.e. lines 12–49 in the current file — with:

```erb
      <div class="form-grid mb-3">
        <div class="form-col-6">
          <label class="field-label">Natureza da operação</label>
          <%= form.select :kind, options_for_select([['Atacado', 'sale'], ['Transferência de Estoque', 'stock_transfer']], @b2b_order.kind), {}, { id: 'kindSelect', class: 'field-input' } %>
        </div>
        <div class="form-col-6">
          <label class="field-label">Número</label>
          <%= text_field_tag :number, (@b2b_order.persisted? ? @b2b_order.id : 'Gerado automaticamente'), class: 'field-input', readonly: true, disabled: true %>
        </div>
      </div>

      <div class="form-grid">
        <div class="form-col-6" id="clientSection">
          <label class="field-label">Cliente</label>
          <input type="text" id="clientSearchInput" class="field-input" placeholder="Buscar cliente por nome/CNPJ..." value="<%= @b2b_order.client&.display_name %>">
          <div id="clientSearchResults" class="list-group mt-2"></div>
          <%= form.hidden_field :client_id, id: 'clientIdField' %>
        </div>

        <div class="form-col-6" id="transferLocationSection">
          <label class="field-label">Local de Destino</label>
          <%= form.collection_select :transfer_location_id, TransferLocation.active.order(:name), :id, :name, { include_blank: 'Selecione...' }, { class: 'field-input' } %>
        </div>

        <div class="form-col-6">
          <label class="field-label">Vendedor</label>
          <%= form.text_field :salesperson_name, class: 'field-input', placeholder: 'Nome do vendedor' %>
        </div>

        <div class="form-col-6">
          <label class="field-label">Lista de preço</label>
          <%= form.select :price_list, options_for_select([['Padrão', 'standard'], ['Transferência', 'transfer']], @b2b_order.price_list), {}, { id: 'priceListSelect', class: 'field-input' } %>
        </div>

        <div class="form-col-6">
          <label class="field-label">Forma de Envio</label>
          <select id="shippingMethodSelect" class="field-input">
            <option value="">Carregando...</option>
          </select>
          <%= form.hidden_field :carrier_shipping_method, id: 'carrierMethodField' %>
        </div>

        <div class="form-col-6" id="carrierSection" style="display: none;">
          <label class="field-label">Transportadora</label>
          <%= form.collection_select :carrier_id, Carrier.active.order(:name), :id, :name, { include_blank: 'Selecione...' }, { class: 'field-input' } %>
          <span class="text-muted-custom d-block mt-1"><i class="fas fa-info-circle me-1"></i><%= link_to 'Cadastrar transportadora', new_carrier_path, target: '_blank' %></span>
        </div>

        <div class="form-col-12 form-check">
          <%= form.check_box :different_shipping_address, id: 'differentShippingAddressCheck' %>
          <label class="form-check-label text-main" for="differentShippingAddressCheck">O endereço de entrega do cliente é diferente do endereço de cobrança</label>
        </div>
      </div>

      <div id="shippingAddressSection" class="form-grid mt-2" style="<%= @b2b_order.different_shipping_address? ? '' : 'display: none;' %>">
        <div class="form-col-6">
          <label class="field-label">Rua</label>
          <%= form.text_field :shipping_street, class: 'field-input' %>
        </div>
        <div class="form-col-6">
          <label class="field-label">Número</label>
          <%= form.text_field :shipping_number, class: 'field-input' %>
        </div>
        <div class="form-col-6">
          <label class="field-label">Complemento</label>
          <%= form.text_field :shipping_complement, class: 'field-input' %>
        </div>
        <div class="form-col-6">
          <label class="field-label">Bairro</label>
          <%= form.text_field :shipping_neighbourhood, class: 'field-input' %>
        </div>
        <div class="form-col-6">
          <label class="field-label">Cidade</label>
          <%= form.text_field :shipping_city, class: 'field-input' %>
        </div>
        <div class="form-col-6">
          <label class="field-label">UF</label>
          <%= form.text_field :shipping_state, class: 'field-input' %>
        </div>
        <div class="form-col-6">
          <label class="field-label">CEP</label>
          <%= form.text_field :shipping_zip, class: 'field-input' %>
        </div>
      </div>
```

- [ ] **Step 4: Add the "Desconto" column to the items table**

In the same file, update the items table header:

```erb
      <table class="orders-table" id="itemsTable">
        <thead>
          <tr><th></th><th>SKU</th><th>Nome</th><th>Qtd</th><th>Preço</th><th>Desconto</th><th>Estoque Correios B2B</th><th></th></tr>
        </thead>
```

And each server-rendered row — add the discount cell between price and stock:

```erb
              <td><%= number_field_tag "b2b_order[b2b_order_items_attributes][#{index}][price]", item.price, step: 0.01, class: 'field-input' %></td>
              <td><%= number_field_tag "b2b_order[b2b_order_items_attributes][#{index}][discount]", item.discount, step: 0.01, min: 0, class: 'field-input' %></td>
              <td class="item-stock-cell" data-sku="<%= item.sku %>">-</td>
```

- [ ] **Step 5: Remove "Salvar Rascunho"**

Replace the `form-actions` block:

```erb
  <div class="form-actions">
    <button type="submit" class="btn-submit">Salvar</button>
  </div>
```

- [ ] **Step 6: Update the JS — kind select toggle, price list aware item pricing, discount column in `addItemRow`, shipping address toggle**

In the `<script>` block (inside `content_for :scripts`), replace the `toggleKindSections` wiring:

```javascript
  function toggleKindSections() {
    var isSale = document.getElementById('kindSelect').value === 'sale';
    document.getElementById('clientSection').style.display = isSale ? '' : 'none';
    document.getElementById('transferLocationSection').style.display = isSale ? 'none' : '';
  }
  document.getElementById('kindSelect').addEventListener('change', toggleKindSections);
  toggleKindSections();

  function currentPriceList() {
    var select = document.getElementById('priceListSelect');
    return select && select.value === 'transfer' ? 'transfer' : 'standard';
  }

  var addrCheck = document.getElementById('differentShippingAddressCheck');
  var addrSection = document.getElementById('shippingAddressSection');
  addrCheck.addEventListener('change', function () {
    addrSection.style.display = addrCheck.checked ? '' : 'none';
  });
```

Replace `addItemRow` to add the discount cell (defaulting new rows to `0`):

```javascript
  function addItemRow(sku, name, quantity, price, imageUrl) {
    var tbody = document.getElementById('itemsTableBody');
    var row = document.createElement('tr');
    row.innerHTML =
      photoCellHtml(sku, imageUrl) +
      '<td><input type="text" class="field-input" name="b2b_order[b2b_order_items_attributes][' + itemIndex + '][sku]" value="' + (sku || '') + '" readonly></td>' +
      '<td><input type="text" class="field-input" name="b2b_order[b2b_order_items_attributes][' + itemIndex + '][name]" value="' + (name || '') + '" readonly></td>' +
      '<td><input type="number" class="field-input" name="b2b_order[b2b_order_items_attributes][' + itemIndex + '][quantity]" value="' + (quantity || 1) + '"></td>' +
      '<td><input type="number" step="0.01" class="field-input" name="b2b_order[b2b_order_items_attributes][' + itemIndex + '][price]" value="' + (price || 0) + '"></td>' +
      '<td><input type="number" step="0.01" min="0" class="field-input" name="b2b_order[b2b_order_items_attributes][' + itemIndex + '][discount]" value="0"></td>' +
      '<td class="item-stock-cell" data-sku="' + (sku || '') + '">-</td>' +
      '<td><button type="button" class="action-btn action-btn--danger remove-item-row"><i class="fas fa-trash"></i></button></td>';
    tbody.appendChild(row);
    itemIndex++;
    if (!imageUrl) queueImageFetch(row.querySelector('.item-photo-cell'));
  }
```

Update the CSV upload handler to pick the price by the current price list:

```javascript
  document.getElementById('csvUploadInput').addEventListener('change', function (e) {
    var file = e.target.files[0];
    if (!file) return;
    var formData = new FormData();
    formData.append('file', file);
    fetch('<%= parse_items_spreadsheet_b2b_orders_path %>', { method: 'POST', body: formData, headers: { 'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]').content } })
      .then(function (r) { return r.json(); })
      .then(function (data) {
        if (!data.success) { alert(data.message); return; }
        data.items.forEach(function (item) {
          var price = currentPriceList() === 'transfer' ? (item.retail_price || 0) : (item.suggested_price || 0);
          addItemRow(item.sku, item.name, item.quantity, price, item.image_url);
        });
      });
  });
```

Update the product picker's `setVariantSelected` to do the same:

```javascript
      function setVariantSelected(cb, variant) {
        if (cb.checked) {
          pickerSelected[variant.sku] = {
            sku: variant.sku,
            name: product.name + ' - ' + variant.option,
            price: currentPriceList() === 'transfer' ? (variant.retail_price || 0) : (variant.price || 0),
            image_url: product.image_url
          };
        } else {
          delete pickerSelected[variant.sku];
        }
      }
```

- [ ] **Step 7: Run the tests to verify everything passes**

Run: `bin/rails test test/controllers/b2b_orders_controller_test.rb test/models/b2b_order_test.rb test/models/b2b_order_item_test.rb test/services/b2b_tiny_service_test.rb test/jobs/sync_b2b_orders_status_job_test.rb`
Expected: PASS (full b2b suite green)

- [ ] **Step 8: Manual smoke test**

Run: `bin/rails server` (or use the `run` skill if available) and, in the browser:
1. Open `/b2b_orders/new`, confirm "Natureza da operação" is a dropdown, "Número" shows "Gerado automaticamente", "Vendedor" and "Lista de preço" appear next to Cliente, and checking "endereço de entrega diferente" reveals the address fields.
2. Add a product via the picker with "Lista de preço" set to "Padrão", confirm the inserted price is the suggested (discounted) one; switch to "Transferência", add another product, confirm that one uses the full retail price.
3. Set a discount on an item row, save the order, confirm it doesn't blow up and the order lands in "Aberto" on the index (a `WebMock`-less local run without valid Tiny credentials will make the background job fail — that's expected outside of a real Tiny sandbox; check the job's `dados_incompletos` fallback message shows up instead of a 500).
4. On the index, confirm the "Todos"/"Aberto"/"Aprovado" tabs show with counts, and clicking "mais" reveals the rest without a page reload.

- [ ] **Step 9: Commit**

```bash
git add app/views/b2b_orders/_form.html.erb test/controllers/b2b_orders_controller_test.rb
git commit -m "Redesign b2b_orders form: natureza da operação, vendedor, lista de preço, endereço de entrega, desconto por item"
```

---

## Amendment (post-implementation): status tabs are responsive, not a fixed primary/secondary split

After implementing Task 3 and Task 7 as written, the user changed the requirement for the index status
tabs: instead of always showing only "Todos"/"Aberto"/"Aprovado" and hiding the other 7 statuses behind
a static "mais" toggle, **all 9 statuses are rendered**, and JS hides whichever ones don't fit the row's
current width behind a "mais" dropdown — recalculated on load and on window resize (a responsive
"priority nav" pattern, matching how the Bling reference screenshot behaves).

This replaces `B2bOrder::PRIMARY_STATUSES` / `SECONDARY_STATUSES` (removed — no longer meaningful) with
a single ordered `B2bOrder::STATUS_LABELS` used to render every tab. The view renders "Todos" plus one
`link_to` per `STATUS_LABELS` key (each tagged `data: { status_key: ... }`), followed by a
`#statusTabMoreWrapper` containing the "mais" toggle button and a `#statusTabDropdown` panel. JS
(`recalcStatusTabs` in `index.html.erb`) measures the row's `clientWidth` against the summed width of
all tabs; if they don't all fit, it moves (via `insertBefore`/`appendChild` — real DOM reparenting, not
clones, since the tabs are plain links with no attached listeners) as many trailing tabs as needed into
the dropdown to fit a `budget` (row width minus the "mais" button's own width), and toggles a
`.status-tab-dropdown--open` class on click (closing on an outside click). This required matching CSS in
`_b2b_orders.scss` (`.status-tab-more-wrapper`, `.status-tab-dropdown`, `.status-tab-dropdown--open`).

No schema or controller changes were needed for this — `@status_counts` already covers every status key.

---

## Amendment 2 (post-implementation): currency formatting, N+1 fix, and a "ver no Tiny" link

Three more fixes came out of manual review/QA on the index page:

1. **Currency formatting.** The app has no `pt-BR` locale file, so plain `number_to_currency(order.total)`
   rendered as `$1,234.50` (Rails' `en` default) instead of Brazilian reais. Fixed by passing explicit
   options: `number_to_currency(order.total, unit: 'R$', separator: ',', delimiter: '.', format: '%u %n')`.
2. **N+1 on `client` (caught by the Bullet gem, already configured in this app).** Task 7's `index` used
   `left_joins(:client)` (needed for the `q` search's raw SQL condition) instead of `includes(:client, ...)`,
   which meant `order.client` in the view issued a separate query per row — exactly the kind of unused/N+1
   eager loading Bullet (`config/environments/development.rb`, `Bullet.alert = true`) flags. Fixed by going
   back to `B2bOrder.includes(:client, :transfer_location, :b2b_order_items)` and adding `.references(:client)`
   only when the raw SQL `where` needs the `clients` table joined — this restores the single preload query
   per association and matches the pre-existing Bullet safelist entries for `B2bOrder`'s `:client` and
   `:transfer_location` (see the comment above those two lines in `development.rb`).
3. **"Ver no Tiny" link.** New `app/helpers/b2b_orders_helper.rb#tiny_order_url(order)`, following the exact
   pattern already used in `app/views/orders/show.html.erb` (`ENV.fetch('TINY_ORDER_URL', 'https://erp.tiny.com.br/vendas#edit/')`)
   for `sale?` orders. For `stock_transfer?` orders (which create a nota fiscal, not a pedido) there was no
   existing URL pattern anywhere in the codebase to copy, so `ENV.fetch('TINY_NOTA_FISCAL_URL', 'https://erp.tiny.com.br/notas_fiscais#edit/')`
   is an educated guess at Tiny's URL scheme, not a confirmed one — flagged to the user to verify/override
   via the env var if wrong. The link (an external-link icon) is rendered in the "Nº pedido" column next to
   the reference number whenever `tiny_reference_id` is present.
