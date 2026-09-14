# Pedidos B2B Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a new "Pedidos" top-level sidebar section with a "Pedidos B2B" screen where a user creates either a regular sale order or a stock-transfer order, picks a carrier fetched live from Tiny, builds the item list by CSV upload and/or manual SKU search (with live Shopify stock shown informationally), saves as draft/saved, and transmits it to Tiny (`pedido.incluir.php` for sales, `nota.fiscal.incluir.php` for transfers) — plus a "Locais de Transferência" CRUD for the transfer destinations (CNPJ + full address) that replaces the hardcoded destination in `CreateNoteTinyJob`.

**Architecture:** Two new models (`TransferLocation`, `B2bOrder` + `B2bOrderItem`), a new `B2bTinyService` (same shape as the existing `TinyService`) wrapping three Tiny API calls, a `TransmitB2bOrderJob` that calls it asynchronously, two new screen-gated controllers (`B2bOrdersController`, `TransferLocationsController`) using the `guard_screen` system already in production, and a new top-level sidebar group. Item entry and the carrier dropdown are AJAX/JS-driven (plain `<script>`, matching the codebase's existing convention — no Stimulus controllers are used for this kind of thing elsewhere).

**Tech Stack:** Rails 7.2.2, MySQL, Minitest + fixtures, Devise 4.9.4, HTTParty (already used by `TinyService`), plain JS in `content_for :scripts` blocks (existing convention).

**Spec:** `docs/superpowers/specs/2026-09-13-b2b-orders-design.md`

## Global Constraints

- `TOKEN_TINY2_PRODUCTION` is the only Tiny account used anywhere in this feature (order creation, nota fiscal creation, shipping-method lookup) — confirmed with the user.
- No carrier CRUD — carriers are fetched live from Tiny (`formas.envio.pesquisa.php`) and only the chosen name/method are stored on the order.
- Stock shown per item is informational only — never blocks saving or transmitting.
- CSV only for the item spreadsheet upload (columns: SKU, Quantidade) — no `.xlsx` parsing.
- `OrderPdv`, `PlannerOrder`, `CreateNoteTinyJob`, and the existing "Correios B2B" pipeline are not touched by this work.
- Every new screen (`b2b_orders`, `transfer_locations`) goes through `ApplicationController.guard_screen`, never a hardcoded `admin_only!`-style check — this repo's whole point of the screen-permission system (see `docs/superpowers/specs/2026-09-13-screen-permissions-design.md`) is that access to new screens is assignable to any profile via "Perfis e Permissões", not hardcoded.
- New DB writes to production go through the same path used for the screen-permissions work: apply migrations directly (no separate test DB exists locally — `development` in `config/database.yml` points at the real production database), verify with targeted read-only/throwaway `rails runner` checks instead of the Minitest suite (which would truncate the real `users`/`api_users` tables via fixtures). Do not run `bin/rails test` against production.
- No `git commit` at any point — the user's standing preference is to leave everything staged, never committed by the agent.
- Every shell command needs `export PATH="$HOME/.rbenv/shims:$PATH"` first (system `ruby` is 2.6, project needs 3.2.2 via rbenv) — and for anything that boots Rails, `set -a; source .env; set +a` first (production env vars, e.g. `SHOPIFY_API_KEY`, are not auto-loaded by dotenv outside development/test).

---

## File Structure

**Create:**
- `db/migrate/20260914000000_create_transfer_locations.rb`
- `db/migrate/20260914000100_create_b2b_orders.rb`
- `db/migrate/20260914000200_create_b2b_order_items.rb`
- `db/migrate/20260914000300_seed_b2b_screen_permissions.rb`
- `app/models/transfer_location.rb`
- `app/models/b2b_order.rb`
- `app/models/b2b_order_item.rb`
- `app/services/b2b_tiny_service.rb`
- `app/jobs/transmit_b2b_order_job.rb`
- `app/controllers/transfer_locations_controller.rb`
- `app/controllers/b2b_orders_controller.rb`
- `app/views/transfer_locations/index.html.erb`, `new.html.erb`, `edit.html.erb`, `_form.html.erb`
- `app/views/b2b_orders/index.html.erb`, `new.html.erb`, `edit.html.erb`, `_form.html.erb`
- `test/models/transfer_location_test.rb`
- `test/models/b2b_order_test.rb`
- `test/services/b2b_tiny_service_test.rb`
- `test/controllers/transfer_locations_controller_test.rb`
- `test/controllers/b2b_orders_controller_test.rb`

**Modify:**
- `app/models/screen.rb` — add `b2b_orders`/`transfer_locations` to `DEFINITIONS`
- `config/routes.rb` — add `resources :transfer_locations` and `resources :b2b_orders` (with collection/member extras)
- `app/views/layouts/partials/_sidebar.html.erb` — new top-level "Pedidos" group + `togglePedidosB2b()` JS
- `Gemfile` — add `gem 'webmock'` to the existing `group :test do` block

---

### Task 1: `TransferLocation` model + migration

**Files:**
- Create: `db/migrate/20260914000000_create_transfer_locations.rb`
- Create: `app/models/transfer_location.rb`
- Test: `test/models/transfer_location_test.rb`

**Interfaces:**
- Produces: `TransferLocation` AR model — `#cnpj_formatted`, scope `.active`, validated CNPJ/address fields, `has_many :b2b_orders, dependent: :restrict_with_error` (consumed by Task 3's `B2bOrder`).

- [ ] **Step 1: Write the migration**

```ruby
# db/migrate/20260914000000_create_transfer_locations.rb
class CreateTransferLocations < ActiveRecord::Migration[7.2]
  def change
    create_table :transfer_locations do |t|
      t.string :name, null: false
      t.string :registration, null: false
      t.string :state_registration
      t.string :street, null: false
      t.string :number, null: false
      t.string :complement
      t.string :neighbourhood, null: false
      t.string :city, null: false
      t.string :state, null: false
      t.string :zip, null: false
      t.boolean :active, null: false, default: true
      t.timestamps
    end
  end
end
```

- [ ] **Step 2: Run the migration against production**

```bash
export PATH="$HOME/.rbenv/shims:$PATH"
set -a; source .env; set +a
RAILS_ENV=production bin/rails db:migrate
```
Expected: `== 20260914000000 CreateTransferLocations: migrated`.

- [ ] **Step 3: Write the failing tests**

```ruby
# test/models/transfer_location_test.rb
require 'test_helper'

class TransferLocationTest < ActiveSupport::TestCase
  def valid_attrs
    {
      name: 'CD Teste', registration: '25.405.327/0001-74',
      street: 'Rua Teste', number: '100', neighbourhood: 'Centro',
      city: 'Belo Horizonte', state: 'MG', zip: '30000-000'
    }
  end

  test 'valid with all required fields' do
    assert TransferLocation.new(valid_attrs).valid?
  end

  test 'invalid without a CNPJ' do
    location = TransferLocation.new(valid_attrs.merge(registration: ''))
    refute location.valid?
  end

  test 'invalid with a malformed CNPJ' do
    location = TransferLocation.new(valid_attrs.merge(registration: '123'))
    refute location.valid?
  end

  test 'cnpj_formatted formats the digits' do
    location = TransferLocation.new(valid_attrs.merge(registration: '25405327000174'))
    assert_equal '25.405.327/0001-74', location.cnpj_formatted
  end

  test 'active scope only returns active locations' do
    active = TransferLocation.create!(valid_attrs)
    inactive = TransferLocation.create!(valid_attrs.merge(name: 'Inativo', active: false))
    assert_includes TransferLocation.active, active
    refute_includes TransferLocation.active, inactive
  end

  test 'cannot be destroyed while it has b2b_orders' do
    location = TransferLocation.create!(valid_attrs)
    user = User.create!(name: 'Teste TL', email: 'teste_tl@example.com', password: 'password123')
    B2bOrder.create!(kind: :stock_transfer, transfer_location: location, user: user)

    refute location.destroy
    assert_includes location.errors[:base], 'Não é possível excluir o registro pois existem registros dependentes'
  end
end
```

Note: the last test (`cannot be destroyed`) references `B2bOrder`, which doesn't exist until Task 3 — it will fail to run (`NameError`) until then. Skip running it in this task's Step 4; run the full file once Task 3 is done (tracked in Task 3's steps).

- [ ] **Step 4: Run the first 5 tests to verify they fail, then pass**

```bash
export PATH="$HOME/.rbenv/shims:$PATH"
set -a; source .env; set +a
RAILS_ENV=production bin/rails runner "puts TransferLocation.new.valid?"
```
(No local test DB exists — see Global Constraints. Use `rails runner` to sanity-check the model boots and validates, same as the screen-permissions work.)

- [ ] **Step 5: Write the model**

```ruby
# app/models/transfer_location.rb
class TransferLocation < ApplicationRecord
  has_many :b2b_orders, dependent: :restrict_with_error

  validates :name, :street, :number, :neighbourhood, :city, :state, :zip,
            presence: true
  validates :registration, presence: true,
                           format: { with: /\A\d{2}\.?\d{3}\.?\d{3}\/?\d{4}-?\d{2}\z/,
                                     message: 'deve ser um CNPJ válido' }

  scope :active, -> { where(active: true) }

  def cnpj_formatted
    registration.gsub(/\D/, '').sub(/(\d{2})(\d{3})(\d{3})(\d{4})(\d{2})/, '\1.\2.\3/\4-\5')
  end
end
```

- [ ] **Step 6: Verify with `rails runner` against production (throwaway, cleaned up)**

```bash
export PATH="$HOME/.rbenv/shims:$PATH"
set -a; source .env; set +a
RAILS_ENV=production bin/rails runner "
loc = TransferLocation.create!(name: '__tmp_verify__', registration: '25.405.327/0001-74', street: 'Rua X', number: '1', neighbourhood: 'B', city: 'BH', state: 'MG', zip: '30000-000')
puts 'cnpj_formatted: ' + loc.cnpj_formatted
puts 'active scope includes it: ' + TransferLocation.active.exists?(loc.id).to_s
loc.destroy
puts 'cleaned up: ' + TransferLocation.exists?(loc.id).to_s
"
```
Expected: `cnpj_formatted: 25.405.327/0001-74`, `active scope includes it: true`, `cleaned up: false`.

- [ ] **Step 7: Syntax-check and stage**

```bash
export PATH="$HOME/.rbenv/shims:$PATH"
ruby -c db/migrate/20260914000000_create_transfer_locations.rb app/models/transfer_location.rb test/models/transfer_location_test.rb
git add db/migrate/20260914000000_create_transfer_locations.rb db/schema.rb app/models/transfer_location.rb test/models/transfer_location_test.rb
```
(No commit — staged only, per Global Constraints.)

---

### Task 2: `Screen` entries + seed migration for the two new screens

**Files:**
- Modify: `app/models/screen.rb`
- Create: `db/migrate/20260914000300_seed_b2b_screen_permissions.rb`

**Interfaces:**
- Consumes: `screen_permissions` table (already exists in production, from the screen-permissions feature).
- Produces: `Screen.keys` now includes `'b2b_orders'` and `'transfer_locations'`; Admin profile (id 1) has both granted.

This task is placed early (before the controllers exist) so `guard_screen :b2b_orders` / `:transfer_locations` have a valid key to reference in Tasks 4 and 7, and so "Perfis e Permissões" shows the new checkboxes as soon as this is deployed — matching the exact ordering rule the earlier screen-permissions spec established (seed before guard).

- [ ] **Step 1: Modify `Screen::DEFINITIONS`**

```ruby
# app/models/screen.rb
class Screen
  DEFINITIONS = {
    users_management:   'Gerenciar Usuários',
    orders:              'Pedidos',
    customers:           'Clientes',
    discounts:           'Descontos',
    logs:                'Logs',
    dashboard_correios:  'Painel de Correios',
    marketing_campaigns: 'Campanhas de Marketing',
    marketing_tasks:     'Tarefas de Marketing',
    b2b_orders:          'Pedidos B2B',
    transfer_locations:  'Locais de Transferência'
  }.freeze

  def self.keys = DEFINITIONS.keys.map(&:to_s)
  def self.options_for_select = DEFINITIONS.map { |k, v| [v, k.to_s] }
  def self.label(key) = DEFINITIONS[key.to_sym]
end
```

- [ ] **Step 2: Write the seed migration**

```ruby
# db/migrate/20260914000300_seed_b2b_screen_permissions.rb
class SeedB2bScreenPermissions < ActiveRecord::Migration[7.2]
  def up
    execute <<-SQL
      INSERT INTO screen_permissions (profile_id, screen_key, created_at, updated_at) VALUES
        (1, 'b2b_orders', NOW(), NOW()),
        (1, 'transfer_locations', NOW(), NOW())
    SQL
  end

  def down
    execute <<-SQL
      DELETE FROM screen_permissions WHERE profile_id = 1 AND screen_key IN ('b2b_orders', 'transfer_locations')
    SQL
  end
end
```

- [ ] **Step 3: Run the migration against production**

```bash
export PATH="$HOME/.rbenv/shims:$PATH"
set -a; source .env; set +a
RAILS_ENV=production bin/rails db:migrate
```

- [ ] **Step 4: Verify**

```bash
export PATH="$HOME/.rbenv/shims:$PATH"
set -a; source .env; set +a
RAILS_ENV=production bin/rails runner "
puts Screen.keys.sort.inspect
admin = Profile.find(Profile::ADMIN)
puts 'admin screen_keys: ' + admin.screen_keys.sort.inspect
"
```
Expected: `Screen.keys` includes `b2b_orders` and `transfer_locations`; Admin's `screen_keys` includes both.

- [ ] **Step 5: Syntax-check and stage**

```bash
export PATH="$HOME/.rbenv/shims:$PATH"
ruby -c app/models/screen.rb db/migrate/20260914000300_seed_b2b_screen_permissions.rb
git add app/models/screen.rb db/migrate/20260914000300_seed_b2b_screen_permissions.rb db/schema.rb
```

---

### Task 3: `B2bOrder` + `B2bOrderItem` models + migrations

**Files:**
- Create: `db/migrate/20260914000100_create_b2b_orders.rb`
- Create: `db/migrate/20260914000200_create_b2b_order_items.rb`
- Create: `app/models/b2b_order.rb`
- Create: `app/models/b2b_order_item.rb`
- Test: `test/models/b2b_order_test.rb`

**Interfaces:**
- Consumes: `Client` (existing), `TransferLocation` (Task 1), `User` (existing).
- Produces: `B2bOrder#transmittable?`, `#sale?`/`#stock_transfer?`/`#draft?` (from `enum :kind`/`:status`), `#shipper?`/`#recipient?` (from `enum :freight_paid_by`); `B2bOrder#b2b_order_items` (consumed by Task 5's `B2bTinyService` and Task 7's controller/form).

- [ ] **Step 1: Write the migrations**

```ruby
# db/migrate/20260914000100_create_b2b_orders.rb
class CreateB2bOrders < ActiveRecord::Migration[7.2]
  def change
    create_table :b2b_orders do |t|
      t.integer :kind, null: false
      t.integer :status, null: false, default: 0
      t.references :client, null: true, foreign_key: true
      t.references :transfer_location, null: true, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :carrier_name
      t.string :carrier_shipping_method
      t.integer :freight_paid_by
      t.decimal :freight_value, precision: 10, scale: 2
      t.string :tiny_reference_id
      t.string :tiny_reference_number
      t.text :error_message
      t.text :notes
      t.timestamps
    end
  end
end
```

```ruby
# db/migrate/20260914000200_create_b2b_order_items.rb
class CreateB2bOrderItems < ActiveRecord::Migration[7.2]
  def change
    create_table :b2b_order_items do |t|
      t.references :b2b_order, null: false, foreign_key: true
      t.string :sku, null: false
      t.string :name
      t.integer :quantity, null: false
      t.decimal :price, precision: 10, scale: 2, null: false
      t.timestamps
    end
  end
end
```

- [ ] **Step 2: Run both migrations against production**

```bash
export PATH="$HOME/.rbenv/shims:$PATH"
set -a; source .env; set +a
RAILS_ENV=production bin/rails db:migrate
```

- [ ] **Step 3: Write the models**

```ruby
# app/models/b2b_order_item.rb
class B2bOrderItem < ApplicationRecord
  belongs_to :b2b_order

  validates :sku, presence: true
  validates :quantity, numericality: { greater_than: 0 }
  validates :price, numericality: { greater_than_or_equal_to: 0 }

  def product
    Product.find_by(sku: sku)
  end
end
```

```ruby
# app/models/b2b_order.rb
class B2bOrder < ApplicationRecord
  belongs_to :client, optional: true
  belongs_to :transfer_location, optional: true
  belongs_to :user
  has_many :b2b_order_items, dependent: :destroy
  accepts_nested_attributes_for :b2b_order_items, allow_destroy: true, reject_if: :all_blank

  enum :kind, { sale: 0, stock_transfer: 1 }
  enum :status, { draft: 0, saved: 1, transmitted: 2, error: 3 }
  enum :freight_paid_by, { shipper: 0, recipient: 1 }

  validates :client, presence: true, if: -> { sale? && !draft? }
  validates :transfer_location, presence: true, if: -> { stock_transfer? && !draft? }
  validate :must_have_items, unless: :draft?

  scope :recent, -> { order(created_at: :desc) }

  def transmittable?
    saved? || error?
  end

  private

  def must_have_items
    errors.add(:base, 'Pedido precisa ter pelo menos um item') if b2b_order_items.empty?
  end
end
```

- [ ] **Step 4: Write the tests (including the `TransferLocation` destroy test deferred from Task 1)**

```ruby
# test/models/b2b_order_test.rb
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

  test 'draft order does not require client, transfer_location or items' do
    order = B2bOrder.new(kind: :sale, status: :draft, user: @user)
    assert order.valid?
  end

  test 'sale order requires a client once not draft' do
    order = B2bOrder.new(kind: :sale, status: :saved, user: @user)
    order.b2b_order_items.build(sku: 'ABC', quantity: 1, price: 10)
    refute order.valid?
    assert_includes order.errors[:client], 'não pode ficar em branco'
  end

  test 'stock_transfer order requires a transfer_location once not draft' do
    order = B2bOrder.new(kind: :stock_transfer, status: :saved, user: @user)
    order.b2b_order_items.build(sku: 'ABC', quantity: 1, price: 10)
    refute order.valid?
    assert_includes order.errors[:transfer_location], 'não pode ficar em branco'
  end

  test 'non-draft order requires at least one item' do
    order = B2bOrder.new(kind: :sale, status: :saved, user: @user, client: @client)
    refute order.valid?
    assert_includes order.errors[:base], 'Pedido precisa ter pelo menos um item'
  end

  test 'saved order is a valid full example' do
    order = B2bOrder.new(kind: :sale, status: :saved, user: @user, client: @client)
    order.b2b_order_items.build(sku: 'ABC', name: 'Produto', quantity: 2, price: 10.5)
    assert order.valid?
  end

  test 'transmittable? is true only for saved or error' do
    order = B2bOrder.new(kind: :sale, status: :draft, user: @user)
    refute order.transmittable?
    order.status = :saved
    assert order.transmittable?
    order.status = :error
    assert order.transmittable?
    order.status = :transmitted
    refute order.transmittable?
  end
end
```

- [ ] **Step 4b: Re-run the `TransferLocation` destroy test now that `B2bOrder` exists**

Run (via `rails runner`, same reasoning as Task 1 Step 4):
```bash
export PATH="$HOME/.rbenv/shims:$PATH"
set -a; source .env; set +a
RAILS_ENV=production bin/rails runner "
loc = TransferLocation.create!(name: '__tmp_verify2__', registration: '25.405.327/0001-74', street: 'Rua X', number: '1', neighbourhood: 'B', city: 'BH', state: 'MG', zip: '30000-000')
user = User.create!(name: '__tmp_user__', email: '__tmp_user__@example.com', password: 'password123')
order = B2bOrder.create!(kind: :stock_transfer, status: :draft, transfer_location: loc, user: user)
puts 'destroy blocked: ' + (!loc.destroy).to_s
order.destroy
loc.destroy
user.destroy
puts 'cleaned up: ' + TransferLocation.exists?(loc.id).to_s
"
```
Expected: `destroy blocked: true`, `cleaned up: false`.

- [ ] **Step 5: Verify the models with `rails runner` (throwaway, cleaned up)**

```bash
export PATH="$HOME/.rbenv/shims:$PATH"
set -a; source .env; set +a
RAILS_ENV=production bin/rails runner "
user = User.create!(name: '__tmp_b2b__', email: '__tmp_b2b__@example.com', password: 'password123')
client = Client.create!(responsible_name: '__tmp_client__')
order = B2bOrder.new(kind: :sale, status: :saved, user: user, client: client)
puts 'invalid without items: ' + (!order.valid?).to_s
order.b2b_order_items.build(sku: 'SKU1', quantity: 1, price: 10)
puts 'valid with item: ' + order.valid?.to_s
order.save!
puts 'transmittable?: ' + order.transmittable?.to_s
order.destroy
client.destroy
user.destroy
"
```
Expected: `invalid without items: true`, `valid with item: true`, `transmittable?: true`.

- [ ] **Step 6: Syntax-check and stage**

```bash
export PATH="$HOME/.rbenv/shims:$PATH"
ruby -c db/migrate/20260914000100_create_b2b_orders.rb db/migrate/20260914000200_create_b2b_order_items.rb app/models/b2b_order.rb app/models/b2b_order_item.rb test/models/b2b_order_test.rb
git add db/migrate/20260914000100_create_b2b_orders.rb db/migrate/20260914000200_create_b2b_order_items.rb db/schema.rb app/models/b2b_order.rb app/models/b2b_order_item.rb test/models/b2b_order_test.rb test/models/transfer_location_test.rb
```

---

### Task 4: `TransferLocationsController` + views

**Files:**
- Create: `app/controllers/transfer_locations_controller.rb`
- Create: `app/views/transfer_locations/index.html.erb`, `new.html.erb`, `edit.html.erb`, `_form.html.erb`
- Modify: `config/routes.rb`
- Test: `test/controllers/transfer_locations_controller_test.rb`

**Interfaces:**
- Consumes: `TransferLocation` (Task 1), `ApplicationController.guard_screen` (already exists in production), `Screen` (Task 2).
- Produces: routes `transfer_locations_path`, `new_transfer_location_path`, `edit_transfer_location_path(location)`.

- [ ] **Step 1: Add the route**

Modify `config/routes.rb` — add near the other top-level resources (next to `resources :profiles`):

```ruby
  resources :transfer_locations
```

- [ ] **Step 2: Write the failing tests**

```ruby
# test/controllers/transfer_locations_controller_test.rb
require 'test_helper'

class TransferLocationsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(name: 'Admin TL', email: 'admin_tl@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
  end

  test 'user without transfer_locations access is redirected' do
    profile = Profile.create!(name: 'Sem Acesso TL')
    user = User.create!(name: 'Sem Acesso TL', email: 'sem_acesso_tl@example.com', password: 'password123')
    user.profiles << profile
    sign_in user

    get transfer_locations_path
    assert_redirected_to root_path
  end

  test 'admin can list, create and update a transfer location' do
    sign_in @admin

    get transfer_locations_path
    assert_response :success

    get new_transfer_location_path
    assert_response :success

    assert_difference 'TransferLocation.count', 1 do
      post transfer_locations_path, params: { transfer_location: {
        name: 'CD Novo', registration: '25.405.327/0001-74', street: 'Rua A',
        number: '10', neighbourhood: 'Bairro', city: 'BH', state: 'MG', zip: '30000-000'
      } }
    end
    location = TransferLocation.find_by(name: 'CD Novo')
    assert_redirected_to transfer_locations_path

    patch transfer_location_path(location), params: { transfer_location: { name: 'CD Renomeado' } }
    assert_equal 'CD Renomeado', location.reload.name
  end

  test 'destroy is blocked when the location still has b2b_orders' do
    sign_in @admin
    location = TransferLocation.create!(
      name: 'CD Com Pedido', registration: '25.405.327/0001-74', street: 'Rua A',
      number: '10', neighbourhood: 'Bairro', city: 'BH', state: 'MG', zip: '30000-000'
    )
    B2bOrder.create!(kind: :stock_transfer, status: :draft, transfer_location: location, user: @admin)

    assert_no_difference 'TransferLocation.count' do
      delete transfer_location_path(location)
    end
    assert_redirected_to transfer_locations_path
  end
end
```

- [ ] **Step 3: Run to verify failure**

```bash
export PATH="$HOME/.rbenv/shims:$PATH"
set -a; source .env; set +a
RAILS_ENV=production bin/rails routes | grep transfer_locations
```
Expected: no output yet (route not added until Step 1 lands — this is a sanity check that the plan's ordering is being followed; re-run after Step 1 to confirm the route exists before writing the controller).

- [ ] **Step 4: Write the controller**

```ruby
# app/controllers/transfer_locations_controller.rb
class TransferLocationsController < ApplicationController
  guard_screen :transfer_locations
  before_action :set_transfer_location, only: [:edit, :update, :destroy]

  def index
    @transfer_locations = TransferLocation.order(:name)
  end

  def new
    @transfer_location = TransferLocation.new
  end

  def create
    @transfer_location = TransferLocation.new(transfer_location_params)
    if @transfer_location.save
      redirect_to transfer_locations_path, notice: 'Local de transferência criado com sucesso.'
    else
      render :new
    end
  end

  def edit; end

  def update
    if @transfer_location.update(transfer_location_params)
      redirect_to transfer_locations_path, notice: 'Local de transferência atualizado com sucesso.'
    else
      render :edit
    end
  end

  def destroy
    if @transfer_location.destroy
      redirect_to transfer_locations_path, notice: 'Local de transferência removido com sucesso.'
    else
      redirect_to transfer_locations_path, alert: @transfer_location.errors.full_messages.to_sentence
    end
  end

  private

  def set_transfer_location
    @transfer_location = TransferLocation.find(params[:id])
  end

  def transfer_location_params
    params.require(:transfer_location).permit(
      :name, :registration, :state_registration, :street, :number,
      :complement, :neighbourhood, :city, :state, :zip, :active
    )
  end
end
```

- [ ] **Step 5: Write the views**

```erb
<%# app/views/transfer_locations/index.html.erb %>
<% content_for :title, "Locais de Transferência" %>

<div class="users-container">
  <div class="page-header">
    <div class="header-left">
      <h1 class="page-title"><i class="fas fa-warehouse me-2"></i>Locais de Transferência</h1>
      <p class="page-subtitle">Destinos usados para transferência de estoque no Tiny</p>
    </div>
    <div class="header-actions">
      <span class="total-badge"><i class="fas fa-list me-1"></i><%= @transfer_locations.size %> local(is)</span>
      <%= link_to new_transfer_location_path, class: "btn-export" do %>
        <i class="fas fa-plus me-2"></i>Novo Local
      <% end %>
    </div>
  </div>

  <div class="table-card">
    <div class="table-card-header">
      <h5 class="table-card-title"><i class="fas fa-list me-2"></i>Lista de Locais</h5>
    </div>

    <% if @transfer_locations.any? %>
      <div class="table-responsive">
        <table class="orders-table">
          <thead>
            <tr>
              <th>Nome</th>
              <th>CNPJ</th>
              <th>Cidade/UF</th>
              <th class="text-center">Status</th>
              <th class="text-end">Ações</th>
            </tr>
          </thead>
          <tbody>
            <% @transfer_locations.each do |location| %>
              <tr>
                <td class="text-main"><%= location.name %></td>
                <td class="text-muted-custom"><%= location.cnpj_formatted %></td>
                <td class="text-muted-custom"><%= location.city %>/<%= location.state %></td>
                <td class="text-center">
                  <span class="status-pill <%= location.active? ? 'status-pill--active' : 'status-pill--inactive' %>">
                    <%= location.active? ? 'Ativo' : 'Inativo' %>
                  </span>
                </td>
                <td class="text-end">
                  <div class="table-actions">
                    <%= link_to edit_transfer_location_path(location), class: "action-btn action-btn--edit" do %>
                      <i class="fas fa-pencil-alt"></i>
                    <% end %>
                    <%= link_to location, method: :delete,
                                class: "action-btn action-btn--danger",
                                data: { confirm: "Tem certeza que deseja excluir este local?" } do %>
                      <i class="fas fa-trash"></i>
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
        <i class="fas fa-warehouse fa-3x mb-3 d-block"></i>
        <h5>Nenhum local cadastrado</h5>
        <%= link_to new_transfer_location_path, class: "btn-export" do %>
          <i class="fas fa-plus me-1"></i>Novo Local
        <% end %>
      </div>
    <% end %>
  </div>
</div>
```

```erb
<%# app/views/transfer_locations/new.html.erb %>
<% content_for :title, "Novo Local de Transferência" %>
<div class="users-container">
  <div class="page-header">
    <div class="header-left">
      <h1 class="page-title"><i class="fas fa-warehouse me-2"></i>Novo Local de Transferência</h1>
    </div>
    <div class="header-actions">
      <%= link_to transfer_locations_path, class: "btn-back" do %><i class="fas fa-arrow-left me-1"></i>Voltar<% end %>
    </div>
  </div>
  <%= render 'form' %>
</div>
```

```erb
<%# app/views/transfer_locations/edit.html.erb %>
<% content_for :title, "Editar Local de Transferência" %>
<div class="users-container">
  <div class="page-header">
    <div class="header-left">
      <h1 class="page-title"><i class="fas fa-warehouse me-2"></i>Editar Local de Transferência</h1>
      <p class="page-subtitle"><%= @transfer_location.name %></p>
    </div>
    <div class="header-actions">
      <%= link_to transfer_locations_path, class: "btn-back" do %><i class="fas fa-arrow-left me-1"></i>Voltar<% end %>
    </div>
  </div>
  <%= render 'form' %>
</div>
```

```erb
<%# app/views/transfer_locations/_form.html.erb %>
<%= form_with model: @transfer_location, local: true, class: 'needs-validation', novalidate: true do |form| %>
  <% if @transfer_location.errors.any? %>
    <div class="form-error-box">
      <i class="fas fa-exclamation-triangle me-2"></i>
      <ul class="mb-0 mt-1">
        <% @transfer_location.errors.full_messages.each do |message| %><li><%= message %></li><% end %>
      </ul>
    </div>
  <% end %>

  <div class="form-section">
    <div class="form-section-header">
      <h5 class="form-section-title"><i class="fas fa-id-badge me-2"></i>Identificação</h5>
    </div>
    <div class="form-section-body">
      <div class="form-grid">
        <div class="form-col-6">
          <label class="field-label">Nome <span class="required">*</span></label>
          <%= form.text_field :name, class: "field-input #{'field-input--error' if @transfer_location.errors[:name].any?}", required: true %>
        </div>
        <div class="form-col-6">
          <label class="field-label">CNPJ <span class="required">*</span></label>
          <%= form.text_field :registration, class: "field-input #{'field-input--error' if @transfer_location.errors[:registration].any?}", required: true, placeholder: "00.000.000/0000-00" %>
        </div>
        <div class="form-col-6">
          <label class="field-label">Inscrição Estadual</label>
          <%= form.text_field :state_registration, class: "field-input" %>
        </div>
      </div>
    </div>
  </div>

  <div class="form-section">
    <div class="form-section-header">
      <h5 class="form-section-title"><i class="fas fa-map-marker-alt me-2"></i>Endereço</h5>
    </div>
    <div class="form-section-body">
      <div class="form-grid">
        <div class="form-col-6">
          <label class="field-label">Rua <span class="required">*</span></label>
          <%= form.text_field :street, class: "field-input", required: true %>
        </div>
        <div class="form-col-2">
          <label class="field-label">Número <span class="required">*</span></label>
          <%= form.text_field :number, class: "field-input", required: true %>
        </div>
        <div class="form-col-4">
          <label class="field-label">Complemento</label>
          <%= form.text_field :complement, class: "field-input" %>
        </div>
        <div class="form-col-4">
          <label class="field-label">Bairro <span class="required">*</span></label>
          <%= form.text_field :neighbourhood, class: "field-input", required: true %>
        </div>
        <div class="form-col-4">
          <label class="field-label">Cidade <span class="required">*</span></label>
          <%= form.text_field :city, class: "field-input", required: true %>
        </div>
        <div class="form-col-2">
          <label class="field-label">UF <span class="required">*</span></label>
          <%= form.text_field :state, class: "field-input", required: true, maxlength: 2 %>
        </div>
        <div class="form-col-2">
          <label class="field-label">CEP <span class="required">*</span></label>
          <%= form.text_field :zip, class: "field-input", required: true %>
        </div>
      </div>
    </div>
  </div>

  <div class="form-section">
    <div class="form-section-header">
      <h5 class="form-section-title"><i class="fas fa-toggle-on me-2"></i>Status</h5>
    </div>
    <div class="form-section-body">
      <div class="form-check form-switch">
        <%= form.check_box :active, class: 'form-check-input', role: 'switch', checked: @transfer_location.new_record? ? true : @transfer_location.active? %>
        <label class="form-check-label text-main fw-bold">Ativo</label>
      </div>
    </div>
  </div>

  <div class="form-actions">
    <%= form.submit (@transfer_location.new_record? ? 'Criar Local' : 'Salvar Alterações'), class: "btn-submit" %>
    <%= link_to "Cancelar", transfer_locations_path, class: "btn-cancel" %>
  </div>
<% end %>
```

- [ ] **Step 6: Run the full controller test suite for this resource — cannot run locally (no test DB); verify instead with `rails runner`-driven request simulation is not practical for controller tests, so use manual smoke check**

```bash
export PATH="$HOME/.rbenv/shims:$PATH"
set -a; source .env; set +a
RAILS_ENV=production bin/rails routes | grep transfer_locations
RAILS_ENV=production bin/rails zeitwerk:check
```
Expected: 7 RESTful routes listed; zeitwerk check passes (catches typos/missing constants in the controller/views before any real request hits them).

- [ ] **Step 7: Syntax-check and stage**

```bash
export PATH="$HOME/.rbenv/shims:$PATH"
ruby -c app/controllers/transfer_locations_controller.rb test/controllers/transfer_locations_controller_test.rb config/routes.rb
git add config/routes.rb app/controllers/transfer_locations_controller.rb app/views/transfer_locations test/controllers/transfer_locations_controller_test.rb
```

---

### Task 5: `webmock` + `B2bTinyService`

**Files:**
- Modify: `Gemfile`
- Create: `app/services/b2b_tiny_service.rb`
- Test: `test/services/b2b_tiny_service_test.rb`

**Interfaces:**
- Consumes: `B2bOrder` (Task 3), `ENV['TOKEN_TINY2_PRODUCTION']`.
- Produces: `B2bTinyService#shipping_methods` (`Array<{name:, method:}>`), `#create_sale_order(b2b_order)` / `#create_stock_transfer(b2b_order)` (`{success:, tiny_reference_id:, tiny_reference_number:}` or `{success: false, error:}`) — consumed by Task 6's job and Task 8's AJAX endpoint.

- [ ] **Step 1: Add `webmock` to the Gemfile**

Modify `Gemfile` — inside the existing `group :test do` block (the one with `capybara`/`selenium-webdriver`):

```ruby
group :test do
  # Use system testing [https://guides.rubyonrails.org/testing.html#system-testing]
  gem "capybara"
  gem "selenium-webdriver"
  gem "webdrivers"
  gem "webmock"
end
```

- [ ] **Step 2: Install the gem**

```bash
export PATH="$HOME/.rbenv/shims:$PATH"
bundle install
```
Expected: `Bundle complete!`, `Gemfile.lock` updated with `webmock` and its dependencies (`crack`, `hashdiff`).

- [ ] **Step 3: Write the failing tests**

```ruby
# test/services/b2b_tiny_service_test.rb
require 'test_helper'
require 'webmock/minitest'

class B2bTinyServiceTest < ActiveSupport::TestCase
  def setup
    ENV['TOKEN_TINY2_PRODUCTION'] = 'fake-token'
    @service = B2bTinyService.new

    @user = User.create!(name: 'Teste Service', email: 'teste_service@example.com', password: 'password123')
    @client = Client.create!(responsible_name: 'Cliente Service', registration: '25.405.327/0001-74')
    @location = TransferLocation.create!(
      name: 'CD Service', registration: '25.405.327/0001-74', street: 'Rua Service',
      number: '1', neighbourhood: 'B', city: 'BH', state: 'MG', zip: '30000-000'
    )
  end

  test 'shipping_methods parses the Tiny response into name/method pairs' do
    stub_request(:get, 'https://api.tiny.com.br/api2/formas.envio.pesquisa.php')
      .to_return(body: {
        retorno: { status: 'OK', registros: [{ id: '782947860', nome: 'Transportadora', situacao: '1', tipo_logistica: '2' }] }
      }.to_json)

    result = @service.shipping_methods
    assert_equal [{ name: 'Transportadora', method: '782947860' }], result
  end

  test 'shipping_methods returns empty array on Tiny error' do
    stub_request(:get, 'https://api.tiny.com.br/api2/formas.envio.pesquisa.php')
      .to_return(body: { retorno: { status: 'Erro' } }.to_json)

    assert_equal [], @service.shipping_methods
  end

  test 'create_sale_order returns success with tiny reference on OK response' do
    order = B2bOrder.create!(kind: :sale, status: :saved, user: @user, client: @client,
                              carrier_name: 'Jamef', carrier_shipping_method: 'jamef')
    order.b2b_order_items.create!(sku: 'SKU1', name: 'Produto 1', quantity: 2, price: 10.5)

    stub_request(:post, 'https://api.tiny.com.br/api2/pedido.incluir.php')
      .to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '111', numero: '222' } } } }.to_json)

    result = @service.create_sale_order(order)
    assert result[:success]
    assert_equal '111', result[:tiny_reference_id]
    assert_equal '222', result[:tiny_reference_number]
  end

  test 'create_sale_order returns failure with the Tiny error message' do
    order = B2bOrder.create!(kind: :sale, status: :saved, user: @user, client: @client)
    order.b2b_order_items.create!(sku: 'SKU1', quantity: 1, price: 1)

    stub_request(:post, 'https://api.tiny.com.br/api2/pedido.incluir.php')
      .to_return(body: { retorno: { status: 'Erro', erros: { erro: 'CPF/CNPJ inválido' } } }.to_json)

    result = @service.create_sale_order(order)
    refute result[:success]
    assert_equal 'CPF/CNPJ inválido', result[:error]
  end

  test 'create_stock_transfer returns success when status_processamento is 3' do
    order = B2bOrder.create!(kind: :stock_transfer, status: :saved, user: @user, transfer_location: @location)
    order.b2b_order_items.create!(sku: 'SKU1', name: 'Produto 1', quantity: 1, price: 5)

    stub_request(:post, 'https://api.tiny.com.br/api2/nota.fiscal.incluir.php')
      .to_return(body: { retorno: { status: 'OK', status_processamento: '3', registros: { registro: { numero: '999' } } } }.to_json)

    result = @service.create_stock_transfer(order)
    assert result[:success]
    assert_equal '999', result[:tiny_reference_id]
  end

  test 'create_stock_transfer returns failure when Tiny rejects the note' do
    order = B2bOrder.create!(kind: :stock_transfer, status: :saved, user: @user, transfer_location: @location)
    order.b2b_order_items.create!(sku: 'SKU1', quantity: 1, price: 5)

    stub_request(:post, 'https://api.tiny.com.br/api2/nota.fiscal.incluir.php')
      .to_return(body: { retorno: { status: 'Erro', status_processamento: '1', registros: { registro: { erro: 'Item sem CFOP' } } } }.to_json)

    result = @service.create_stock_transfer(order)
    refute result[:success]
    assert_equal 'Item sem CFOP', result[:error]
  end
end
```

- [ ] **Step 4: Write the service**

```ruby
# app/services/b2b_tiny_service.rb
class B2bTinyService
  BASE_URL = 'https://api.tiny.com.br/api2'.freeze

  def initialize
    @token = ENV.fetch('TOKEN_TINY2_PRODUCTION')
  end

  def shipping_methods
    response = HTTParty.get("#{BASE_URL}/formas.envio.pesquisa.php",
                             query: { token: @token, formato: 'json' })
    parsed = JSON.parse(response.body).with_indifferent_access
    return [] unless parsed.dig(:retorno, :status) == 'OK'

    Array(parsed.dig(:retorno, :registros)).map do |r|
      { name: r[:nome], method: r[:id] }
    end
  rescue StandardError => e
    Rails.logger.error "B2bTinyService#shipping_methods exception: #{e.message}"
    []
  end

  def create_sale_order(b2b_order)
    response = do_post('pedido.incluir.php', pedido: build_pedido(b2b_order).to_json)
    parse_pedido_response(response)
  rescue StandardError => e
    Rails.logger.error "B2bTinyService#create_sale_order exception: #{e.message}"
    { success: false, error: e.message }
  end

  def create_stock_transfer(b2b_order)
    response = do_post('nota.fiscal.incluir.php', nota: build_nota_fiscal(b2b_order).to_json)
    parse_nota_response(response)
  rescue StandardError => e
    Rails.logger.error "B2bTinyService#create_stock_transfer exception: #{e.message}"
    { success: false, error: e.message }
  end

  private

  def do_post(endpoint, body_params)
    HTTParty.post("#{BASE_URL}/#{endpoint}",
                   body: { token: @token, formato: 'json' }.merge(body_params))
  end

  def build_pedido(b2b_order)
    client = b2b_order.client

    {
      situacao: 'aberto',
      data_pedido: b2b_order.created_at.strftime('%d/%m/%Y'),
      itens: b2b_order.b2b_order_items.map do |i|
        { item: { codigo: i.sku, descricao: i.name, unidade: 'UN', quantidade: i.quantity, valor_unitario: i.price.to_f } }
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
      nome_transportador: b2b_order.carrier_name,
      forma_frete: b2b_order.carrier_shipping_method,
      frete_por_conta: b2b_order.shipper? ? 'R' : 'D',
      valor_frete: b2b_order.freight_value.to_f,
      obs: b2b_order.notes.presence || "Pedido B2B ##{b2b_order.id}"
    }
  end

  def build_nota_fiscal(b2b_order)
    transfer_location = b2b_order.transfer_location

    items = b2b_order.b2b_order_items.map do |i|
      { codigo: i.sku, descricao: i.name, unidade: 'UN', quantidade: i.quantity.to_s,
        valor_unitario: format('%.2f', i.price), tipo: 'P', cfop: '5152' }
    end

    valor_produtos = items.sum { |it| it[:valor_unitario].to_f * it[:quantidade].to_f }
    valor_icms = (valor_produtos * 0.18).round(2)
    valor_nota = (valor_produtos + valor_icms).round(2)

    {
      nota_fiscal: {
        tipo: 'S',
        natureza_operacao: 'CFOP 5152 - Transferência de mercadoria adquirida ou recebida de terceiros',
        data_emissao: Time.current.strftime('%d/%m/%Y'),
        cliente: {
          nome: transfer_location.name,
          tipo_pessoa: 'J',
          cpf_cnpj: transfer_location.registration,
          ie: transfer_location.state_registration.presence || '',
          endereco: transfer_location.street,
          numero: transfer_location.number,
          complemento: transfer_location.complement.presence || '',
          bairro: transfer_location.neighbourhood,
          cidade: transfer_location.city,
          uf: transfer_location.state,
          cep: transfer_location.zip
        },
        itens: items.map { |item| { item: item } },
        transportador: { nome: b2b_order.carrier_name },
        forma_frete: b2b_order.carrier_shipping_method,
        frete_por_conta: b2b_order.shipper? ? 'R' : 'D',
        valor_frete: b2b_order.freight_value.to_f,
        valor_produtos: format('%.2f', valor_produtos),
        valor_icms: format('%.2f', valor_icms),
        base_icms: format('%.2f', valor_produtos),
        valor_nota: format('%.2f', valor_nota),
        valor_faturado: format('%.2f', valor_nota),
        obs: "Transferência B2B ##{b2b_order.id} | #{b2b_order.notes}"
      }
    }
  end

  def parse_pedido_response(response)
    retorno = JSON.parse(response.body).with_indifferent_access[:retorno]
    if retorno[:status] == 'OK'
      registro = retorno.dig(:registros, :registro)
      { success: true, tiny_reference_id: registro&.dig(:id)&.to_s, tiny_reference_number: registro&.dig(:numero)&.to_s }
    else
      erro = retorno.dig(:erros, :erro)
      { success: false, error: Array(erro).join(', ').presence || erro.to_s.presence || 'Erro desconhecido na API Tiny' }
    end
  end

  def parse_nota_response(response)
    retorno = JSON.parse(response.body).with_indifferent_access[:retorno]
    registro = retorno.dig(:registros, :registro)
    erro = registro&.dig(:erro)

    if retorno[:status_processamento] == '3' && retorno[:status] == 'OK'
      { success: true, tiny_reference_id: registro&.dig(:numero)&.to_s, tiny_reference_number: registro&.dig(:numero)&.to_s }
    else
      { success: false, error: erro.presence || 'Erro desconhecido na API Tiny' }
    end
  end
end
```

- [ ] **Step 5: Run the service tests**

No local test DB (Global Constraints) — run a syntax/load check instead, then rely on Task 5's tests being executed the next time this repo's Minitest suite runs against a real test database (flag this to the user rather than claiming it passed):

```bash
export PATH="$HOME/.rbenv/shims:$PATH"
set -a; source .env; set +a
RAILS_ENV=production bin/rails zeitwerk:check
ruby -c app/services/b2b_tiny_service.rb test/services/b2b_tiny_service_test.rb
```

- [ ] **Step 6: Manual verification against the real Tiny API (read-only call)**

`shipping_methods` is a GET with no side effects — safe to call for real once, to confirm the endpoint/response shape assumed in the tests matches reality:

```bash
export PATH="$HOME/.rbenv/shims:$PATH"
set -a; source .env; set +a
RAILS_ENV=production bin/rails runner "pp B2bTinyService.new.shipping_methods"
```
Expected: an array of `{name:, method:}` hashes (or `[]` if the Tiny account has no shipping methods registered — either way, confirm no exception and inspect the shape against what the tests assume; if the real field names differ, fix `shipping_methods` and its test before moving on).

- [ ] **Step 7: Stage**

```bash
git add Gemfile Gemfile.lock app/services/b2b_tiny_service.rb test/services/b2b_tiny_service_test.rb
```

---

### Task 6: `TransmitB2bOrderJob`

**Files:**
- Create: `app/jobs/transmit_b2b_order_job.rb`

**Interfaces:**
- Consumes: `B2bTinyService` (Task 5), `B2bOrder` (Task 3).
- Produces: enqueued via `TransmitB2bOrderJob.perform_later(b2b_order.id)` — consumed by Task 7's controller `transmit` action.

- [ ] **Step 1: Write the job**

```ruby
# app/jobs/transmit_b2b_order_job.rb
class TransmitB2bOrderJob < ActiveJob::Base
  queue_as :default

  def perform(b2b_order_id)
    order = B2bOrder.find(b2b_order_id)
    service = B2bTinyService.new

    result = order.sale? ? service.create_sale_order(order) : service.create_stock_transfer(order)

    if result[:success]
      order.update!(status: :transmitted, tiny_reference_id: result[:tiny_reference_id], tiny_reference_number: result[:tiny_reference_number])
    else
      order.update!(status: :error, error_message: result[:error])
    end
  end
end
```

- [ ] **Step 2: Verify end-to-end with a stubbed `B2bTinyService` via `rails runner` (throwaway, cleaned up)**

This exercises the job without hitting the real Tiny API:

```bash
export PATH="$HOME/.rbenv/shims:$PATH"
set -a; source .env; set +a
RAILS_ENV=production bin/rails runner "
user = User.create!(name: '__tmp_job__', email: '__tmp_job__@example.com', password: 'password123')
client = Client.create!(responsible_name: '__tmp_job_client__', registration: '25.405.327/0001-74')
order = B2bOrder.new(kind: :sale, status: :saved, user: user, client: client, carrier_name: 'Jamef')
order.b2b_order_items.build(sku: 'SKU1', quantity: 1, price: 1)
order.save!

B2bTinyService.define_method(:create_sale_order) { |_| { success: true, tiny_reference_id: '123', tiny_reference_number: '456' } }
TransmitB2bOrderJob.perform_now(order.id)
order.reload
puts 'status: ' + order.status
puts 'tiny_reference_id: ' + order.tiny_reference_id.to_s

order.destroy
client.destroy
user.destroy
"
```
Expected: `status: transmitted`, `tiny_reference_id: 123`.

- [ ] **Step 3: Syntax-check and stage**

```bash
export PATH="$HOME/.rbenv/shims:$PATH"
ruby -c app/jobs/transmit_b2b_order_job.rb
git add app/jobs/transmit_b2b_order_job.rb
```

---

### Task 7: `B2bOrdersController` — core CRUD + transmit (no AJAX endpoints yet)

**Files:**
- Create: `app/controllers/b2b_orders_controller.rb`
- Modify: `config/routes.rb`
- Test: `test/controllers/b2b_orders_controller_test.rb`

**Interfaces:**
- Consumes: `B2bOrder`/`B2bOrderItem` (Task 3), `TransmitB2bOrderJob` (Task 6), `guard_screen` (existing).
- Produces: routes `b2b_orders_path`, `new_b2b_order_path`, `edit_b2b_order_path`, `transmit_b2b_order_path` — consumed by Task 9's views.

- [ ] **Step 1: Add the routes**

Modify `config/routes.rb`:

```ruby
  resources :b2b_orders do
    collection do
      get :shipping_methods
      post :parse_items_spreadsheet
      get :product_stock
      get :search_product
    end
    member do
      post :transmit
    end
  end
```

(The four collection actions are wired up in Task 8 — declared now so routing doesn't change again, but their controller methods are added there. Leaving them declared-but-unimplemented for one task is fine since nothing links to them until Task 9's views exist.)

- [ ] **Step 2: Write the failing tests**

```ruby
# test/controllers/b2b_orders_controller_test.rb
require 'test_helper'

class B2bOrdersControllerTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(name: 'Admin B2B', email: 'admin_b2b@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @client = Client.create!(responsible_name: 'Cliente B2B Test', registration: '25.405.327/0001-74')
  end

  test 'user without b2b_orders access is redirected' do
    profile = Profile.create!(name: 'Sem Acesso B2B')
    user = User.create!(name: 'Sem Acesso B2B', email: 'sem_acesso_b2b@example.com', password: 'password123')
    user.profiles << profile
    sign_in user

    get b2b_orders_path
    assert_redirected_to root_path
  end

  test 'admin can create a draft without items or client' do
    sign_in @admin

    assert_difference 'B2bOrder.count', 1 do
      post b2b_orders_path, params: { b2b_order: { kind: 'sale', status: 'draft' } }
    end
    assert_redirected_to b2b_orders_path
  end

  test 'admin can create a saved sale order with client and items' do
    sign_in @admin

    assert_difference 'B2bOrder.count', 1 do
      post b2b_orders_path, params: { b2b_order: {
        kind: 'sale', status: 'saved', client_id: @client.id,
        b2b_order_items_attributes: [{ sku: 'SKU1', name: 'Produto', quantity: 2, price: 10 }]
      } }
    end
    order = B2bOrder.last
    assert order.saved?
    assert_equal 1, order.b2b_order_items.count
  end

  test 'saving without items when not draft re-renders with errors' do
    sign_in @admin

    assert_no_difference 'B2bOrder.count' do
      post b2b_orders_path, params: { b2b_order: { kind: 'sale', status: 'saved', client_id: @client.id } }
    end
    assert_response :unprocessable_entity
  end

  test 'transmit enqueues the job only when transmittable' do
    sign_in @admin
    order = B2bOrder.create!(kind: :sale, status: :draft, user: @admin, client: @client)

    assert_no_enqueued_jobs only: TransmitB2bOrderJob do
      post transmit_b2b_order_path(order)
    end
    assert_redirected_to b2b_orders_path

    order.update!(status: :saved)
    order.b2b_order_items.create!(sku: 'SKU1', quantity: 1, price: 1)

    assert_enqueued_with(job: TransmitB2bOrderJob, args: [order.id]) do
      post transmit_b2b_order_path(order)
    end
  end
end
```

- [ ] **Step 3: Write the controller**

```ruby
# app/controllers/b2b_orders_controller.rb
class B2bOrdersController < ApplicationController
  guard_screen :b2b_orders
  before_action :set_b2b_order, only: [:edit, :update, :transmit]

  def index
    @b2b_orders = B2bOrder.includes(:client, :transfer_location, :user).recent
    @b2b_orders = @b2b_orders.where(status: params[:status]) if params[:status].present?
    @b2b_orders = @b2b_orders.where(kind: params[:kind]) if params[:kind].present?
  end

  def new
    @b2b_order = B2bOrder.new(kind: :sale)
  end

  def create
    @b2b_order = B2bOrder.new(b2b_order_params)
    @b2b_order.user = current_user

    if @b2b_order.save
      redirect_to b2b_orders_path, notice: 'Pedido salvo com sucesso.'
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @b2b_order.update(b2b_order_params)
      redirect_to b2b_orders_path, notice: 'Pedido atualizado com sucesso.'
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def transmit
    unless @b2b_order.transmittable?
      redirect_to b2b_orders_path, alert: 'Este pedido não pode ser transmitido.'
      return
    end

    TransmitB2bOrderJob.perform_later(@b2b_order.id)
    redirect_to b2b_orders_path, notice: 'Pedido enviado para transmissão ao Tiny.'
  end

  private

  def set_b2b_order
    @b2b_order = B2bOrder.find(params[:id])
  end

  def b2b_order_params
    params.require(:b2b_order).permit(
      :kind, :status, :client_id, :transfer_location_id, :carrier_name,
      :carrier_shipping_method, :freight_paid_by, :freight_value, :notes,
      b2b_order_items_attributes: [:id, :sku, :name, :quantity, :price, :_destroy]
    )
  end
end
```

- [ ] **Step 4: Verify routes and boot**

```bash
export PATH="$HOME/.rbenv/shims:$PATH"
set -a; source .env; set +a
RAILS_ENV=production bin/rails routes | grep b2b_orders
```
Expected: 7 RESTful routes + `transmit_b2b_order` (member POST) + 4 collection GET/POST routes (these will 404/error if hit before Task 8, which is fine — nothing links to them yet).

Note: `zeitwerk:check` and `rails runner` smoke checks are deferred to the end of Step 5 in Task 8, once the collection actions referenced by the routes above actually exist as controller methods — until then `zeitwerk:check` passes (it only checks constant autoloading, not that every route has a matching action).

- [ ] **Step 5: Verify with `rails runner` (throwaway, cleaned up) — simulates what the controller test would check**

```bash
export PATH="$HOME/.rbenv/shims:$PATH"
set -a; source .env; set +a
RAILS_ENV=production bin/rails runner "
user = User.create!(name: '__tmp_ctrl__', email: '__tmp_ctrl__@example.com', password: 'password123')
client = Client.create!(responsible_name: '__tmp_ctrl_client__', registration: '25.405.327/0001-74')

draft = B2bOrder.new(kind: :sale, status: :draft, user: user)
puts 'draft valid without items/client: ' + draft.valid?.to_s

order = B2bOrder.new(kind: :sale, status: :saved, user: user, client: client)
order.b2b_order_items.build(sku: 'SKU1', name: 'P', quantity: 1, price: 1)
order.save!
puts 'saved order transmittable?: ' + order.transmittable?.to_s

order.destroy
client.destroy
user.destroy
"
```
Expected: `draft valid without items/client: true`, `saved order transmittable?: true`.

- [ ] **Step 6: Syntax-check and stage**

```bash
export PATH="$HOME/.rbenv/shims:$PATH"
ruby -c app/controllers/b2b_orders_controller.rb test/controllers/b2b_orders_controller_test.rb config/routes.rb
git add config/routes.rb app/controllers/b2b_orders_controller.rb test/controllers/b2b_orders_controller_test.rb
```

---

### Task 8: AJAX collection endpoints on `B2bOrdersController`

**Files:**
- Modify: `app/controllers/b2b_orders_controller.rb`

**Interfaces:**
- Consumes: `B2bTinyService#shipping_methods` (Task 5), `Product`/Shopify GraphQL (existing pattern from `OrderPdvsController`).
- Produces: `GET b2b_orders/shipping_methods`, `POST b2b_orders/parse_items_spreadsheet`, `GET b2b_orders/product_stock`, `GET b2b_orders/search_product` — all JSON, consumed by Task 9's form JS.

- [ ] **Step 1: Add the four actions**

Modify `app/controllers/b2b_orders_controller.rb` — add before the `private` line:

```ruby
  def shipping_methods
    methods = Rails.cache.fetch('tiny2_shipping_methods', expires_in: 10.minutes) do
      B2bTinyService.new.shipping_methods
    end
    render json: { success: true, shipping_methods: methods }
  end

  def parse_items_spreadsheet
    file = params[:file]
    unless file.present?
      render json: { success: false, message: 'Nenhum arquivo enviado.' }
      return
    end

    csv = CSV.parse(file.read.force_encoding('UTF-8'), headers: true)
    items = csv.filter_map do |row|
      sku = row['SKU']
      quantity = row['Quantidade'].to_i
      next if sku.blank? || quantity <= 0

      product = Product.find_by(sku: sku)
      { sku: sku, name: product&.shopify_product_name, quantity: quantity }
    end

    if items.empty?
      render json: { success: false, message: 'Nenhum item válido encontrado na planilha (colunas esperadas: SKU, Quantidade).' }
    else
      render json: { success: true, items: items }
    end
  rescue StandardError => e
    render json: { success: false, message: "Erro ao processar planilha: #{e.message}" }
  end

  def product_stock
    sku = params[:sku]
    product = Product.find_by(sku: sku)

    unless product&.shopify_variant_id.present?
      render json: { success: true, quantity: 0, status: 'error', message: 'Produto não encontrado' }
      return
    end

    render json: { success: true, **shopify_stock_for(product) }
  end

  def search_product
    query = params[:query].to_s.strip
    if query.blank?
      render json: { success: false, message: 'Query não fornecida' }
      return
    end

    products = Product.where('LOWER(sku) LIKE :q OR LOWER(shopify_product_name) LIKE :q', q: "%#{query.downcase}%").limit(10)

    render json: { success: true, products: products.map { |p| { id: p.id, sku: p.sku, name: p.shopify_product_name, **shopify_stock_for(p) } } }
  end
```

And add these two private helpers (reusing the Shopify GraphQL pattern already in `OrderPdvsController#get_product_stock`/`#create_shopify_session`):

```ruby
  def create_shopify_session
    ShopifyAPI::Auth::Session.new(shop: 'chasebrasil.myshopify.com', access_token: ENV.fetch('LAGOA_SECA_TOKEN_APP'))
  end

  def shopify_stock_for(product)
    query = <<~GRAPHQL
      query {
        productVariant(id: "gid://shopify/ProductVariant/#{product.shopify_variant_id}") {
          inventoryQuantity
        }
      }
    GRAPHQL

    client = ShopifyAPI::Clients::Graphql::Admin.new(session: create_shopify_session)
    response = client.query(query: query)
    variant = response.body.dig('data', 'productVariant')

    quantity = variant&.dig('inventoryQuantity') || 0
    status = quantity > 10 ? 'high' : (quantity.positive? ? 'low' : 'out')
    { quantity: quantity, status: status }
  rescue StandardError => e
    Rails.logger.error "B2bOrdersController#shopify_stock_for exception: #{e.message}"
    { quantity: 0, status: 'error' }
  end
```

Also require CSV at the top of the file:

```ruby
require 'csv'

class B2bOrdersController < ApplicationController
```

- [ ] **Step 2: Verify with `rails runner`**

```bash
export PATH="$HOME/.rbenv/shims:$PATH"
set -a; source .env; set +a
RAILS_ENV=production bin/rails zeitwerk:check
```
Expected: `All is good!` — confirms no typos in the new methods.

- [ ] **Step 3: Manual CSV parse check (no DB writes, no HTTP)**

```bash
export PATH="$HOME/.rbenv/shims:$PATH"
set -a; source .env; set +a
RAILS_ENV=production bin/rails runner "
require 'csv'
csv = CSV.parse(\"SKU,Quantidade\nABC123,5\n,10\nXYZ999,0\n\", headers: true)
items = csv.filter_map { |row| next if row['SKU'].blank? || row['Quantidade'].to_i <= 0; { sku: row['SKU'], quantity: row['Quantidade'].to_i } }
pp items
"
```
Expected: `[{:sku=>"ABC123", :quantity=>5}]` — confirms the blank-SKU and zero-quantity rows are correctly skipped.

- [ ] **Step 4: Syntax-check and stage**

```bash
export PATH="$HOME/.rbenv/shims:$PATH"
ruby -c app/controllers/b2b_orders_controller.rb
git add app/controllers/b2b_orders_controller.rb
```

---

### Task 9: `B2bOrders` views (index, form with item builder, carrier dropdown, CSV upload)

**Files:**
- Create: `app/views/b2b_orders/index.html.erb`, `new.html.erb`, `edit.html.erb`, `_form.html.erb`

**Interfaces:**
- Consumes: all four AJAX endpoints from Task 8, `b2b_orders_path`/`transmit_b2b_order_path` from Task 7, `search_clients_path` (existing, `ClientsController#search`), `TransferLocation.active` (Task 1).

- [ ] **Step 1: Index view**

```erb
<%# app/views/b2b_orders/index.html.erb %>
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
      <%= select_tag :status, options_for_select([['Todos status', ''], ['Rascunho', 'draft'], ['Salvo', 'saved'], ['Transmitido', 'transmitted'], ['Erro', 'error']], params[:status]), class: 'field-input', onchange: 'this.form.submit()' %>
      <%= select_tag :kind, options_for_select([['Todos tipos', ''], ['Pedido Comum', 'sale'], ['Transferência de Estoque', 'stock_transfer']], params[:kind]), class: 'field-input', onchange: 'this.form.submit()' %>
    <% end %>

    <% if @b2b_orders.any? %>
      <div class="table-responsive">
        <table class="orders-table">
          <thead>
            <tr>
              <th>#</th>
              <th>Tipo</th>
              <th>Destino</th>
              <th class="text-center">Status</th>
              <th>Referência Tiny</th>
              <th class="text-end">Ações</th>
            </tr>
          </thead>
          <tbody>
            <% @b2b_orders.each do |order| %>
              <tr>
                <td class="text-main">#<%= order.id %></td>
                <td><%= order.sale? ? 'Pedido Comum' : 'Transferência de Estoque' %></td>
                <td class="text-muted-custom"><%= order.sale? ? order.client&.display_name : order.transfer_location&.name %></td>
                <td class="text-center">
                  <span class="status-pill <%= order.transmitted? ? 'status-pill--active' : (order.error? ? 'status-pill--inactive' : '') %>">
                    <%= { 'draft' => 'Rascunho', 'saved' => 'Salvo', 'transmitted' => 'Transmitido', 'error' => 'Erro' }[order.status] %>
                  </span>
                </td>
                <td class="text-muted-custom"><%= order.tiny_reference_number.presence || '-' %></td>
                <td class="text-end">
                  <div class="table-actions">
                    <%= link_to edit_b2b_order_path(order), class: "action-btn action-btn--edit" do %><i class="fas fa-pencil-alt"></i><% end %>
                    <% if order.transmittable? %>
                      <%= button_to transmit_b2b_order_path(order), method: :post, class: "action-btn action-btn--edit", form: { data: { turbo_confirm: 'Transmitir este pedido para o Tiny?' } } do %>
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
```

- [ ] **Step 2: `new.html.erb` / `edit.html.erb`**

```erb
<%# app/views/b2b_orders/new.html.erb %>
<% content_for :title, "Novo Pedido B2B" %>
<div class="users-container">
  <div class="page-header">
    <div class="header-left"><h1 class="page-title"><i class="fas fa-handshake me-2"></i>Novo Pedido B2B</h1></div>
    <div class="header-actions">
      <%= link_to b2b_orders_path, class: "btn-back" do %><i class="fas fa-arrow-left me-1"></i>Voltar<% end %>
    </div>
  </div>
  <%= render 'form' %>
</div>
```

```erb
<%# app/views/b2b_orders/edit.html.erb %>
<% content_for :title, "Editar Pedido B2B" %>
<div class="users-container">
  <div class="page-header">
    <div class="header-left">
      <h1 class="page-title"><i class="fas fa-handshake me-2"></i>Editar Pedido B2B</h1>
      <p class="page-subtitle">#<%= @b2b_order.id %></p>
    </div>
    <div class="header-actions">
      <%= link_to b2b_orders_path, class: "btn-back" do %><i class="fas fa-arrow-left me-1"></i>Voltar<% end %>
    </div>
  </div>
  <%= render 'form' %>
</div>
```

- [ ] **Step 3: `_form.html.erb`**

```erb
<%# app/views/b2b_orders/_form.html.erb %>
<%= form_with model: @b2b_order, local: true, id: 'b2bOrderForm' do |form| %>
  <% if @b2b_order.errors.any? %>
    <div class="form-error-box">
      <i class="fas fa-exclamation-triangle me-2"></i>
      <ul class="mb-0 mt-1"><% @b2b_order.errors.full_messages.each do |m| %><li><%= m %></li><% end %></ul>
    </div>
  <% end %>

  <div class="form-section">
    <div class="form-section-header"><h5 class="form-section-title"><i class="fas fa-tag me-2"></i>Tipo do Pedido</h5></div>
    <div class="form-section-body">
      <div class="form-grid">
        <div class="form-col-6 form-check">
          <%= form.radio_button :kind, 'sale', id: 'kind_sale', checked: @b2b_order.sale? || @b2b_order.new_record? %>
          <label class="form-check-label text-main" for="kind_sale">Pedido Comum</label>
        </div>
        <div class="form-col-6 form-check">
          <%= form.radio_button :kind, 'stock_transfer', id: 'kind_stock_transfer', checked: @b2b_order.stock_transfer? %>
          <label class="form-check-label text-main" for="kind_stock_transfer">Transferência de Estoque</label>
        </div>
      </div>
    </div>
  </div>

  <div class="form-section" id="clientSection">
    <div class="form-section-header"><h5 class="form-section-title"><i class="fas fa-building me-2"></i>Cliente</h5></div>
    <div class="form-section-body">
      <input type="text" id="clientSearchInput" class="field-input" placeholder="Buscar cliente por nome/CNPJ..." value="<%= @b2b_order.client&.display_name %>">
      <div id="clientSearchResults" class="list-group mt-2"></div>
      <%= form.hidden_field :client_id, id: 'clientIdField' %>
    </div>
  </div>

  <div class="form-section" id="transferLocationSection">
    <div class="form-section-header"><h5 class="form-section-title"><i class="fas fa-warehouse me-2"></i>Local de Destino</h5></div>
    <div class="form-section-body">
      <%= form.collection_select :transfer_location_id, TransferLocation.active.order(:name), :id, :name, { include_blank: 'Selecione...' }, { class: 'field-input' } %>
    </div>
  </div>

  <div class="form-section">
    <div class="form-section-header"><h5 class="form-section-title"><i class="fas fa-truck me-2"></i>Transportadora e Frete</h5></div>
    <div class="form-section-body">
      <div class="form-grid">
        <div class="form-col-4">
          <label class="field-label">Transportadora</label>
          <select id="carrierSelect" class="field-input">
            <option value="">Carregando...</option>
          </select>
          <%= form.hidden_field :carrier_name, id: 'carrierNameField' %>
          <%= form.hidden_field :carrier_shipping_method, id: 'carrierMethodField' %>
        </div>
        <div class="form-col-4">
          <label class="field-label">Frete por conta</label>
          <%= form.select :freight_paid_by, [['Remetente', 'shipper'], ['Destinatário', 'recipient']], { include_blank: false }, { class: 'field-input' } %>
        </div>
        <div class="form-col-4">
          <label class="field-label">Valor do frete</label>
          <%= form.number_field :freight_value, step: 0.01, class: 'field-input' %>
        </div>
      </div>
    </div>
  </div>

  <div class="form-section">
    <div class="form-section-header"><h5 class="form-section-title"><i class="fas fa-boxes me-2"></i>Itens</h5></div>
    <div class="form-section-body">
      <div class="d-flex gap-2 mb-3 flex-wrap">
        <input type="file" id="csvUploadInput" accept=".csv" class="field-input" style="max-width: 300px;">
        <input type="text" id="manualSkuInput" class="field-input" placeholder="Buscar produto por SKU/nome..." style="max-width: 300px;">
      </div>
      <div id="manualSearchResults" class="list-group mb-3"></div>

      <table class="orders-table" id="itemsTable">
        <thead>
          <tr><th>SKU</th><th>Nome</th><th>Qtd</th><th>Preço</th><th>Estoque</th><th></th></tr>
        </thead>
        <tbody id="itemsTableBody">
          <% @b2b_order.b2b_order_items.each_with_index do |item, index| %>
            <tr>
              <td>
                <%= hidden_field_tag "b2b_order[b2b_order_items_attributes][#{index}][id]", item.id %>
                <%= text_field_tag "b2b_order[b2b_order_items_attributes][#{index}][sku]", item.sku, class: 'field-input' %>
              </td>
              <td><%= text_field_tag "b2b_order[b2b_order_items_attributes][#{index}][name]", item.name, class: 'field-input' %></td>
              <td><%= number_field_tag "b2b_order[b2b_order_items_attributes][#{index}][quantity]", item.quantity, class: 'field-input' %></td>
              <td><%= number_field_tag "b2b_order[b2b_order_items_attributes][#{index}][price]", item.price, step: 0.01, class: 'field-input' %></td>
              <td class="item-stock-cell" data-sku="<%= item.sku %>">-</td>
              <td><button type="button" class="action-btn action-btn--danger remove-item-row"><i class="fas fa-trash"></i></button></td>
            </tr>
          <% end %>
        </tbody>
      </table>
      <span class="text-muted-custom d-block mt-2"><i class="fas fa-info-circle me-1"></i>Estoque exibido é só informativo — não bloqueia o envio.</span>
    </div>
  </div>

  <div class="form-section">
    <div class="form-section-body">
      <label class="field-label">Observações</label>
      <%= form.text_area :notes, class: 'field-input', rows: 3 %>
    </div>
  </div>

  <div class="form-actions">
    <button type="submit" name="b2b_order[status]" value="draft" class="btn-cancel">Salvar Rascunho</button>
    <button type="submit" name="b2b_order[status]" value="saved" class="btn-submit">Salvar</button>
  </div>
<% end %>

<% content_for :scripts do %>
<script>
document.addEventListener('DOMContentLoaded', function () {
  var itemIndex = <%= @b2b_order.b2b_order_items.size %>;

  function toggleKindSections() {
    var isSale = document.getElementById('kind_sale').checked;
    document.getElementById('clientSection').style.display = isSale ? '' : 'none';
    document.getElementById('transferLocationSection').style.display = isSale ? 'none' : '';
  }
  document.getElementById('kind_sale').addEventListener('change', toggleKindSections);
  document.getElementById('kind_stock_transfer').addEventListener('change', toggleKindSections);
  toggleKindSections();

  // Transportadora via AJAX
  fetch('<%= shipping_methods_b2b_orders_path %>')
    .then(function (r) { return r.json(); })
    .then(function (data) {
      var select = document.getElementById('carrierSelect');
      select.innerHTML = '<option value="">Selecione...</option>';
      (data.shipping_methods || []).forEach(function (m) {
        var opt = document.createElement('option');
        opt.value = m.method;
        opt.textContent = m.name;
        opt.dataset.name = m.name;
        if (m.method === '<%= @b2b_order.carrier_shipping_method %>') opt.selected = true;
        select.appendChild(opt);
      });
    });
  document.getElementById('carrierSelect').addEventListener('change', function (e) {
    var opt = e.target.selectedOptions[0];
    document.getElementById('carrierNameField').value = opt ? (opt.dataset.name || '') : '';
    document.getElementById('carrierMethodField').value = e.target.value;
  });

  // Cliente via AJAX (reaproveita ClientsController#search)
  var clientTimeout;
  document.getElementById('clientSearchInput').addEventListener('input', function (e) {
    clearTimeout(clientTimeout);
    var q = e.target.value;
    clientTimeout = setTimeout(function () {
      fetch('<%= search_clients_path %>?q=' + encodeURIComponent(q))
        .then(function (r) { return r.json(); })
        .then(function (data) {
          var box = document.getElementById('clientSearchResults');
          box.innerHTML = '';
          (data.clients || []).forEach(function (c) {
            var item = document.createElement('button');
            item.type = 'button';
            item.className = 'list-group-item list-group-item-action';
            item.textContent = c.display_name + ' - ' + c.registration;
            item.addEventListener('click', function () {
              document.getElementById('clientIdField').value = c.id;
              document.getElementById('clientSearchInput').value = c.display_name;
              box.innerHTML = '';
            });
            box.appendChild(item);
          });
        });
    }, 300);
  });

  function addItemRow(sku, name, quantity, price) {
    var tbody = document.getElementById('itemsTableBody');
    var row = document.createElement('tr');
    row.innerHTML =
      '<td><input type="text" class="field-input" name="b2b_order[b2b_order_items_attributes][' + itemIndex + '][sku]" value="' + (sku || '') + '"></td>' +
      '<td><input type="text" class="field-input" name="b2b_order[b2b_order_items_attributes][' + itemIndex + '][name]" value="' + (name || '') + '"></td>' +
      '<td><input type="number" class="field-input" name="b2b_order[b2b_order_items_attributes][' + itemIndex + '][quantity]" value="' + (quantity || 1) + '"></td>' +
      '<td><input type="number" step="0.01" class="field-input" name="b2b_order[b2b_order_items_attributes][' + itemIndex + '][price]" value="' + (price || 0) + '"></td>' +
      '<td class="item-stock-cell" data-sku="' + (sku || '') + '">-</td>' +
      '<td><button type="button" class="action-btn action-btn--danger remove-item-row"><i class="fas fa-trash"></i></button></td>';
    tbody.appendChild(row);
    itemIndex++;
    fetchStockFor(row.querySelector('.item-stock-cell'));
  }

  document.getElementById('itemsTableBody').addEventListener('click', function (e) {
    var btn = e.target.closest('.remove-item-row');
    if (btn) btn.closest('tr').remove();
  });

  function fetchStockFor(cell) {
    var sku = cell.dataset.sku;
    if (!sku) return;
    fetch('<%= product_stock_b2b_orders_path %>?sku=' + encodeURIComponent(sku))
      .then(function (r) { return r.json(); })
      .then(function (data) { cell.textContent = data.quantity + ' (' + data.status + ')'; });
  }
  document.querySelectorAll('.item-stock-cell').forEach(fetchStockFor);

  // Upload de planilha (tempo real)
  document.getElementById('csvUploadInput').addEventListener('change', function (e) {
    var file = e.target.files[0];
    if (!file) return;
    var formData = new FormData();
    formData.append('file', file);
    fetch('<%= parse_items_spreadsheet_b2b_orders_path %>', { method: 'POST', body: formData, headers: { 'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]').content } })
      .then(function (r) { return r.json(); })
      .then(function (data) {
        if (!data.success) { alert(data.message); return; }
        data.items.forEach(function (item) { addItemRow(item.sku, item.name, item.quantity, 0); });
      });
  });

  // Busca manual de produto
  var searchTimeout;
  document.getElementById('manualSkuInput').addEventListener('input', function (e) {
    clearTimeout(searchTimeout);
    var q = e.target.value;
    searchTimeout = setTimeout(function () {
      if (!q) { document.getElementById('manualSearchResults').innerHTML = ''; return; }
      fetch('<%= search_product_b2b_orders_path %>?query=' + encodeURIComponent(q))
        .then(function (r) { return r.json(); })
        .then(function (data) {
          var box = document.getElementById('manualSearchResults');
          box.innerHTML = '';
          (data.products || []).forEach(function (p) {
            var item = document.createElement('button');
            item.type = 'button';
            item.className = 'list-group-item list-group-item-action';
            item.textContent = p.sku + ' - ' + p.name + ' (estoque: ' + p.quantity + ')';
            item.addEventListener('click', function () {
              addItemRow(p.sku, p.name, 1, 0);
              box.innerHTML = '';
              document.getElementById('manualSkuInput').value = '';
            });
            box.appendChild(item);
          });
        });
    }, 300);
  });
});
</script>
<% end %>
```

- [ ] **Step 4: Verify with `zeitwerk:check` + manual smoke check**

```bash
export PATH="$HOME/.rbenv/shims:$PATH"
set -a; source .env; set +a
RAILS_ENV=production bin/rails zeitwerk:check
RAILS_ENV=production bin/rails runner "
ApplicationController.render(template: 'b2b_orders/index', assigns: { b2b_orders: B2bOrder.none }) rescue puts 'render check needs a request context — skip, verified via routes + zeitwerk instead'
puts 'OK'
"
```
This is a light check (full view rendering needs a request/session context that `rails runner` doesn't have) — the real verification is the manual browser check in Task 11.

- [ ] **Step 5: Stage**

```bash
git add app/views/b2b_orders
```

---

### Task 10: Sidebar — new "Pedidos" top-level group

**Files:**
- Modify: `app/views/layouts/partials/_sidebar.html.erb`

**Interfaces:**
- Consumes: `b2b_orders_path`, `transfer_locations_path` (Tasks 4, 7), `current_user&.can_access_screen?` (existing, from the screen-permissions feature).

- [ ] **Step 1: Add the new group**

Modify `app/views/layouts/partials/_sidebar.html.erb` — insert right after the "Usuários" group's closing `</div>` (the one that currently sits right before `<% if current_user&.admin? || current_user&.profiles&.any?(&:marketing_profile?) %>` for the CRM group):

```erb
        <% if current_user&.can_access_screen?('b2b_orders') || current_user&.can_access_screen?('transfer_locations') %>
          <div class="nav-item nav-group-collapsible">
            <div class="nav-group-header-collapsible" onclick="togglePedidosB2b()">
              <div class="nav-group-title">
                <i class="fas fa-handshake"></i>
                <span class="nav-text">Pedidos</span>
              </div>
              <i class="fas fa-chevron-right collapse-icon" id="pedidosB2bIcon"></i>
            </div>
            <div class="nav-group-dropdown" id="pedidosB2bDropdown">
              <div class="dropdown-content">
                <% if current_user&.can_access_screen?('b2b_orders') %>
                  <%= link_to b2b_orders_path, class: "dropdown-link #{'active' if controller_name == 'b2b_orders'}" do %>
                    <i class="fas fa-file-invoice-dollar"></i>
                    <span>Pedidos B2B</span>
                  <% end %>
                <% end %>
                <% if current_user&.can_access_screen?('transfer_locations') %>
                  <%= link_to transfer_locations_path, class: "dropdown-link #{'active' if controller_name == 'transfer_locations'}" do %>
                    <i class="fas fa-warehouse"></i>
                    <span>Locais de Transferência</span>
                  <% end %>
                <% end %>
              </div>
            </div>
          </div>
        <% end %>

```

Exact insertion point (`old_string` for the edit tool): right after the "Usuários" group's closing `</div></div></div>` and before the blank line + `<% if current_user&.admin? || current_user&.profiles&.any?(&:marketing_profile?) %>` line that opens the "CRM" group. In the file today that boundary reads:

```erb
              <% end %>
            </div>
          </div>
        </div>

        <% if current_user&.admin? || current_user&.profiles&.any?(&:marketing_profile?) %>
```

The new block goes between the `</div>` (Usuários) and the blank line before the CRM `<% if %>`.

- [ ] **Step 2: Add the `togglePedidosB2b()` JS function**

Modify the same file's `<script>` block — add next to the other `toggle*()` functions (after `toggleUsuarios()`, matching the existing `toggleDropdown(id, iconId, selector)` helper already defined above them):

```js
function togglePedidosB2b() {
  toggleDropdown("pedidosB2bDropdown", "pedidosB2bIcon", '[onclick="togglePedidosB2b()"]')
}
```

- [ ] **Step 3: Verify with `rails runner`**

```bash
export PATH="$HOME/.rbenv/shims:$PATH"
set -a; source .env; set +a
RAILS_ENV=production bin/rails runner "
admin = User.joins(:profiles).find_by(profiles: { id: Profile::ADMIN })
puts 'admin can_access_screen?(b2b_orders): ' + admin.can_access_screen?('b2b_orders').to_s
puts 'admin can_access_screen?(transfer_locations): ' + admin.can_access_screen?('transfer_locations').to_s
"
```
Expected: both `true` (seeded to Admin in Task 2).

- [ ] **Step 4: Syntax-check the ERB (basic tag-balance check) and stage**

```bash
export PATH="$HOME/.rbenv/shims:$PATH"
ruby -e "require 'erb'; ERB.new(File.read('app/views/layouts/partials/_sidebar.html.erb')).src" >/dev/null && echo "ERB parses OK"
git add app/views/layouts/partials/_sidebar.html.erb
```

---

### Task 11: Full verification pass

**Files:** none (verification only)

- [ ] **Step 1: `zeitwerk:check` across the whole app**

```bash
export PATH="$HOME/.rbenv/shims:$PATH"
set -a; source .env; set +a
RAILS_ENV=production bin/rails zeitwerk:check
```
Expected: `All is good!`

- [ ] **Step 2: Full route list sanity check**

```bash
export PATH="$HOME/.rbenv/shims:$PATH"
set -a; source .env; set +a
RAILS_ENV=production bin/rails routes | grep -E "b2b_orders|transfer_locations"
```
Expected: all routes from Tasks 4 and 7 present, no duplicates, no errors.

- [ ] **Step 3: `db:migrate:status` — confirm every migration in this plan is `up` in production**

```bash
export PATH="$HOME/.rbenv/shims:$PATH"
set -a; source .env; set +a
RAILS_ENV=production bin/rails db:migrate:status | tail -10
```
Expected: the four migrations from Tasks 1–3 (`create_transfer_locations`, `create_b2b_orders`, `create_b2b_order_items`, `seed_b2b_screen_permissions`) all show `up`.

- [ ] **Step 4: `db:schema:dump` to sync `db/schema.rb` with the production DB**

(Production skips the automatic schema dump after `db:migrate` — same issue hit during the screen-permissions work — so this must be run explicitly.)

```bash
export PATH="$HOME/.rbenv/shims:$PATH"
set -a; source .env; set +a
RAILS_ENV=production bin/rails db:schema:dump
git add db/schema.rb
```

- [ ] **Step 5: End-to-end throwaway smoke test (models → service stub → job), cleaned up**

```bash
export PATH="$HOME/.rbenv/shims:$PATH"
set -a; source .env; set +a
RAILS_ENV=production bin/rails runner "
user = User.create!(name: '__tmp_e2e__', email: '__tmp_e2e__@example.com', password: 'password123')
location = TransferLocation.create!(name: '__tmp_e2e_loc__', registration: '25.405.327/0001-74', street: 'Rua', number: '1', neighbourhood: 'B', city: 'BH', state: 'MG', zip: '30000-000')

order = B2bOrder.new(kind: :stock_transfer, status: :saved, user: user, transfer_location: location, carrier_name: 'Jamef')
order.b2b_order_items.build(sku: 'SKUX', name: 'Produto X', quantity: 3, price: 12.5)
order.save!
puts 'order valid+saved: true'
puts 'transmittable?: ' + order.transmittable?.to_s

B2bTinyService.define_method(:create_stock_transfer) { |_| { success: true, tiny_reference_id: '777', tiny_reference_number: '777' } }
TransmitB2bOrderJob.perform_now(order.id)
order.reload
puts 'status after transmit: ' + order.status

order.destroy
location.destroy
user.destroy
puts 'cleaned up'
"
```
Expected: `order valid+saved: true`, `transmittable?: true`, `status after transmit: transmitted`, `cleaned up`.

- [ ] **Step 6: Manual browser check**

Start the server and, logged in as an Admin user:
- Sidebar shows a new "Pedidos" group (own toggle, own icon) alongside Usuários/CRM/Correios B2C/Correios B2B/Planejador/Produtos — not nested inside any of them.
- "Locais de Transferência" → create one real (or throwaway) location with a valid CNPJ/address, confirm it lists and edits correctly.
- "Pedidos B2B" → New Pedido:
  - Toggle between "Pedido Comum" and "Transferência de Estoque" swaps the Cliente/Local section without a page reload.
  - Transportadora dropdown populates from the live Tiny call (or shows empty if the Tiny 2 account has none registered — confirm no JS error either way).
  - Upload a small CSV (`SKU,Quantidade` header) and confirm rows appear in the items table immediately.
  - Search a known SKU manually and confirm it adds a row with a stock number next to it.
  - "Salvar Rascunho" with no client/items succeeds. "Salvar" without items shows a validation error. "Salvar" with a client + items succeeds.
  - From the index, "Transmitir" on a saved order enqueues the job (check Sidekiq or the order's `status` flips to `transmitted`/`error` shortly after).
- Log in as a non-admin user with no profile access to `b2b_orders`/`transfer_locations` and confirm the "Pedidos" group is entirely absent from the sidebar, and visiting `/b2b_orders` directly redirects with "Acesso negado."
- In "Perfis e Permissões", confirm "Pedidos B2B" and "Locais de Transferência" appear as checkboxes and can be granted to a non-Admin profile.

- [ ] **Step 7: Final `git status` check**

```bash
git status
```
Expected: every file from this plan shows as staged (`Changes to be committed`); nothing committed (per Global Constraints).

