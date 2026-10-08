# Catálogos B2B Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Catálogos B2B montados no Honey, com página pública (linha Gymshark) onde o lojista envia uma encomenda, que vira pedido de venda B2B; mais PDF do catálogo.

**Architecture:** Cinco tabelas (`b2b_catalogs`, `b2b_catalog_products` = cor, `b2b_catalog_variants` = tamanho, `b2b_catalog_orders` = encomenda, `b2b_catalog_order_items`). Estoque/fotos gravados de hora em hora por `B2bCatalogs::Refresher` (reaproveita `B2bStockAvailability`). Honey: `B2bCatalogsController` (montagem), `B2bCatalogOrdersController` (encomendas), pré-preenchimento do `B2bOrdersController#new`. Público: `PublicCatalogsController` (sem login, layout próprio, JSON embutido + JS puro). PDF com Prawn + `rqrcode`.

**Tech Stack:** Rails 7.2, MySQL, ActiveJob/Sidekiq, Minitest + WebMock, ERB + JS puro, SCSS, Prawn, rqrcode.

**Spec:** `docs/superpowers/specs/2026-10-08-b2b-catalogs-design.md`

**Ordem de execução:** 1 → 2 → 3 → 4 → 5 → 6 → 7.

## Global Constraints

- **Nunca rodar `git commit`.** Nenhuma task tem passo de commit.
- **Nunca rodar `db:migrate`/`db:seed` no banco de development** (é produção). Migrations só no MySQL temporário (`<scratchpad>/newdb.sh <nome>`; servidor: `mysqld --datadir=<scratchpad>/mydata --socket=/tmp/chase_my.sock --port=3390 --bind-address=127.0.0.1 --mysqlx=OFF`). `db/schema.rb` gerado num banco limpo; charset das tabelas novas `utf8mb4` / `utf8mb4_0900_ai_ci`, igual às demais.
- Testes: `RAILS_ENV=test TEST_DATABASE_URL=mysql2://root@127.0.0.1:3390/<db> PARALLEL_WORKERS=1 bin/rails test ...`. Baseline: 7 falhas preexistentes (HomeController ×3, Tickets::AddMessage ×2, TicketNotifier, TicketOverdueJob).
- **Sem preço** no catálogo, na página pública, na encomenda e no PDF.
- Número exato de estoque nunca aparece em texto na página pública (só `disponível` / `últimas unidades` / `esgotado`).
- Níveis: `sold_out` se disponível ≤ 0; `low` se ≤ 5; senão `available`.
- Atualização de estoque/fotos: **a cada 1 hora** (rake `b2b_catalogs:refresh` no Heroku Scheduler).
- Coluna de modelo chama-se `style_name` (não `model_name`, que colide com `ActiveModel::Naming`). Status "nova" da encomenda é o enum `pending` (não `new`, que colide com `.new`).
- Textos em português; página pública muito bonita e animada, mobile-first, tema claro.

## Review Focus

1. **Lojista manda quantidade acima do disponível ou variante de outro catálogo** (requisição forjada) → servidor recusa com mensagem, nada é gravado. Teste na Task 5.
2. **Encomenda convertida ou catálogo encerrado recebendo envio** → recusado; página mostra o aviso. Teste na Task 5.
3. **CNPJ com máscara, inválido ou repetido** → normalizado para dígitos; inválido recusado; mesmo CNPJ reabre/atualiza a mesma encomenda (não duplica). Teste nas Tasks 1 e 5.
4. **Shopify ou Correios fora do ar no refresh** → mantém fotos/estoque anteriores, não quebra o job. Teste na Task 2.
5. **Remover uma cor do catálogo que já tem itens em encomendas** → itens daquela cor somem das encomendas (dependent destroy) e a tela avisa antes. Teste na Task 3.

---

### Task 1: Tabelas, models, CNPJ e separação Modelo/Cor

**Files:**
- Create: `db/migrate/20261008140000_create_b2b_catalogs.rb`
- Create: `app/models/b2b_catalog.rb`, `app/models/b2b_catalog_product.rb`, `app/models/b2b_catalog_variant.rb`, `app/models/b2b_catalog_order.rb`, `app/models/b2b_catalog_order_item.rb`
- Create: `app/services/b2b_catalogs/cnpj.rb`, `app/services/b2b_catalogs/name_splitter.rb`
- Modify: `db/schema.rb`
- Test: `test/models/b2b_catalog_test.rb`, `test/models/b2b_catalog_order_test.rb`, `test/services/b2b_catalogs/name_splitter_test.rb`, `test/services/b2b_catalogs/cnpj_test.rb`

**Interfaces:**
- Produces:
  - `B2bCatalog` (`kind` enum `general`/`client` com `prefix: true` → `kind_general?`, `kind_client?`; `status` `active`/`closed`; `public_token`; `#regenerate_public_token!`; `#styles -> Array<[style_name, Array<B2bCatalogProduct>]>`; `#quantity_error(Hash{variant_id=>qty}) -> String|nil`; `accepts_nested_attributes_for :products`).
  - `B2bCatalogProduct` (`style_name`, `color_name`, `position`, `image_urls` (Array), virtual `skus` usado no create para criar as variantes; `#main_image`).
  - `B2bCatalogVariant` (`sku`, `size`, `available`, `availability` enum `available`/`low`/`sold_out`; `.availability_for(Integer) -> Symbol`; `LOW_STOCK = 5`).
  - `B2bCatalogOrder` (`status` enum `pending`/`seen`/`converted`; `customer_name`, `customer_registration` (dígitos), `edit_token`; `#replace_items!(Hash, edited_by:)`, `#convert!(B2bOrder)`, `#matching_client`, `#total_pieces`, `#editable?`; `STATUS_LABELS`).
  - `B2bCatalogOrderItem` (`quantity`, `variant`).
  - `B2bCatalogs::Cnpj.valid?(String) -> Boolean`, `B2bCatalogs::Cnpj.digits(String) -> String`, `B2bCatalogs::Cnpj.format(String) -> String`.
  - `B2bCatalogs::NameSplitter.split(Array<String>) -> Hash{name => [style, color]}`.

- [ ] **Step 1: Write the failing tests**

`test/services/b2b_catalogs/name_splitter_test.rb`:
```ruby
require 'test_helper'

class B2bCatalogs::NameSplitterTest < ActiveSupport::TestCase
  test 'products sharing a prefix form a style and the rest is the color' do
    result = B2bCatalogs::NameSplitter.split(['Legging Apex Seamless Ash', 'Legging Apex Seamless Sky'])

    assert_equal ['Legging Apex Seamless', 'Ash'], result['Legging Apex Seamless Ash']
    assert_equal ['Legging Apex Seamless', 'Sky'], result['Legging Apex Seamless Sky']
  end

  test 'multi-word colors are kept whole when a sibling shares the style' do
    result = B2bCatalogs::NameSplitter.split(['Legging Pure Seamless Tibetan Red', 'Legging Pure Seamless Black'])

    assert_equal ['Legging Pure Seamless', 'Tibetan Red'], result['Legging Pure Seamless Tibetan Red']
  end

  test 'a product without siblings uses the last word as the color' do
    result = B2bCatalogs::NameSplitter.split(['Top Harmony Pink', 'Legging Caos Seamless Tibetan Red'])

    assert_equal ['Top Harmony', 'Pink'], result['Top Harmony Pink']
    assert_equal ['Legging Caos Seamless Tibetan', 'Red'], result['Legging Caos Seamless Tibetan Red']
  end

  test 'a one-word name is its own style with no color' do
    assert_equal ['Meia', ''], B2bCatalogs::NameSplitter.split(['Meia'])['Meia']
  end
end
```

`test/services/b2b_catalogs/cnpj_test.rb`:
```ruby
require 'test_helper'

class B2bCatalogs::CnpjTest < ActiveSupport::TestCase
  test 'valid accepts masked and plain CNPJs with correct check digits' do
    assert B2bCatalogs::Cnpj.valid?('25.405.327/0001-74')
    assert B2bCatalogs::Cnpj.valid?('25405327000174')
  end

  test 'valid rejects wrong check digits, repeated digits and wrong length' do
    refute B2bCatalogs::Cnpj.valid?('25.405.327/0001-75')
    refute B2bCatalogs::Cnpj.valid?('11111111111111')
    refute B2bCatalogs::Cnpj.valid?('123')
    refute B2bCatalogs::Cnpj.valid?(nil)
  end

  test 'format masks fourteen digits' do
    assert_equal '25.405.327/0001-74', B2bCatalogs::Cnpj.format('25405327000174')
  end
end
```

`test/models/b2b_catalog_test.rb`:
```ruby
require 'test_helper'

class B2bCatalogTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(name: 'Catalogo', email: 'catalogo_model@example.com', password: 'password123')
    Product.create!(sku: 'LEG-ASH-G', shopify_product_name: 'Legging Apex Seamless Ash', option1: 'G', shopify_product_id: '1', image_url: 'https://img/ash.jpg')
    Product.create!(sku: 'LEG-ASH-P', shopify_product_name: 'Legging Apex Seamless Ash', option1: 'P', shopify_product_id: '1')
    Product.create!(sku: 'LEG-ASH-M', shopify_product_name: 'Legging Apex Seamless Ash', option1: 'M', shopify_product_id: '1')
  end

  def build_catalog(**attrs)
    B2bCatalog.create!({ title: 'Verão', user: @user, products_attributes: [
      { style_name: 'Legging Apex Seamless', color_name: 'Ash', position: 0, skus: %w[LEG-ASH-G LEG-ASH-P LEG-ASH-M] }
    ] }.merge(attrs))
  end

  test 'creates a public token and variants ordered by size from the given skus' do
    catalog = build_catalog
    product = catalog.products.first

    assert catalog.public_token.length >= 32
    assert_equal %w[P M G], product.variants.map(&:size)
    assert_equal '1', product.shopify_product_id
    assert_equal ['https://img/ash.jpg'], product.image_urls
    assert product.variants.all?(&:sold_out?)
  end

  test 'regenerate_public_token! changes the link' do
    catalog = build_catalog
    old = catalog.public_token
    catalog.regenerate_public_token!
    refute_equal old, catalog.reload.public_token
  end

  test 'a client catalog needs a client and a general one drops it' do
    refute B2bCatalog.new(title: 'X', user: @user, kind: :client).valid?
    client = Client.create!(responsible_name: 'Loja', registration: '25.405.327/0001-74')
    general = B2bCatalog.create!(title: 'Y', user: @user, kind: :general, client: client)
    assert_nil general.client
  end

  test 'styles groups colors by style keeping position order' do
    catalog = build_catalog
    catalog.products.create!(style_name: 'Top Harmony', color_name: 'Pink', position: 1, skus: [])

    assert_equal ['Legging Apex Seamless', 'Top Harmony'], catalog.styles.map(&:first)
  end

  test 'quantity_error refuses variants of other catalogs and quantities above available' do
    catalog = build_catalog
    variant = catalog.variants.first
    variant.update!(available: 3, availability: :low)

    assert_nil catalog.quantity_error(variant.id => 3)
    assert_match(/acima do disponível/, catalog.quantity_error(variant.id => 4))
    assert_match(/fora deste catálogo/, catalog.quantity_error(999_999 => 1))
  end

  test 'availability_for maps quantities to levels' do
    assert_equal :sold_out, B2bCatalogVariant.availability_for(0)
    assert_equal :low, B2bCatalogVariant.availability_for(5)
    assert_equal :available, B2bCatalogVariant.availability_for(6)
  end

  test 'removing a color removes its order items' do
    catalog = build_catalog
    order = catalog.catalog_orders.create!(customer_name: 'Loja', customer_registration: '25.405.327/0001-74')
    order.replace_items!({ catalog.variants.first.id => 1 }, edited_by: 'customer')

    catalog.update!(products_attributes: [{ id: catalog.products.first.id, _destroy: '1' }])

    assert_equal 0, order.items.reload.count
  end
end
```

`test/models/b2b_catalog_order_test.rb`:
```ruby
require 'test_helper'

class B2bCatalogOrderTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(name: 'Encomenda', email: 'encomenda_model@example.com', password: 'password123')
    Product.create!(sku: 'A-P', shopify_product_name: 'Top A Black', option1: 'P')
    Product.create!(sku: 'A-M', shopify_product_name: 'Top A Black', option1: 'M')
    @catalog = B2bCatalog.create!(title: 'Geral', user: @user, products_attributes: [{ style_name: 'Top A', color_name: 'Black', skus: %w[A-P A-M] }])
  end

  test 'registration is stored as digits and must be a valid CNPJ on general catalogs' do
    order = @catalog.catalog_orders.create!(customer_name: 'Loja', customer_registration: '25.405.327/0001-74')
    assert_equal '25405327000174', order.customer_registration
    assert order.pending?
    assert order.edit_token.present?

    bad = @catalog.catalog_orders.new(customer_name: 'Loja', customer_registration: '25.405.327/0001-75')
    refute bad.valid?
    assert_includes bad.errors.full_messages.join, 'CNPJ inválido'
  end

  test 'one order per CNPJ in a catalog' do
    @catalog.catalog_orders.create!(customer_name: 'Loja', customer_registration: '25405327000174')
    refute @catalog.catalog_orders.new(customer_name: 'Outra', customer_registration: '25.405.327/0001-74').valid?
  end

  test 'replace_items! keeps only positive quantities of this catalog variants' do
    order = @catalog.catalog_orders.create!(customer_name: 'Loja', customer_registration: '25405327000174')
    p_variant, m_variant = @catalog.variants.to_a

    order.replace_items!({ p_variant.id => 2, m_variant.id => 0, 999_999 => 4 }, edited_by: 'Ana')

    assert_equal [[p_variant.id, 2]], order.items.pluck(:b2b_catalog_variant_id, :quantity)
    assert_equal 'Ana', order.last_edited_by
    assert_equal 2, order.total_pieces
  end

  test 'convert! links the order and blocks edits' do
    order = @catalog.catalog_orders.create!(customer_name: 'Loja', customer_registration: '25405327000174')
    b2b_order = B2bOrder.new(kind: :sale, user: @user, client: Client.create!(responsible_name: 'C'))
    b2b_order.b2b_order_items.build(sku: 'A-P', quantity: 1, price: 1)
    b2b_order.save!

    order.convert!(b2b_order)

    assert order.converted?
    assert_equal b2b_order, order.b2b_order
    refute order.editable?
  end

  test 'matching_client finds the client by CNPJ digits whatever the mask' do
    client = Client.create!(responsible_name: 'Loja Centro', registration: '25.405.327/0001-74')
    order = @catalog.catalog_orders.create!(customer_name: 'Loja', customer_registration: '25405327000174')

    assert_equal client, order.matching_client
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `... bin/rails test test/models/b2b_catalog_test.rb test/models/b2b_catalog_order_test.rb test/services/b2b_catalogs`
Expected: ERROR `uninitialized constant` (B2bCatalog / B2bCatalogs).

- [ ] **Step 3: Migration**

`db/migrate/20261008140000_create_b2b_catalogs.rb`:
```ruby
class CreateB2bCatalogs < ActiveRecord::Migration[7.2]
  def change
    create_table :b2b_catalogs do |t|
      t.string :title, null: false
      t.integer :kind, null: false, default: 0
      t.references :client, foreign_key: true
      t.integer :status, null: false, default: 0
      t.string :public_token, null: false
      t.text :notes
      t.references :user, null: false, foreign_key: true
      t.datetime :stock_refreshed_at
      t.timestamps
    end
    add_index :b2b_catalogs, :public_token, unique: true

    create_table :b2b_catalog_products do |t|
      t.references :b2b_catalog, null: false, foreign_key: true
      t.string :shopify_product_id
      t.string :style_name, null: false
      t.string :color_name, null: false, default: ''
      t.integer :position, null: false, default: 0
      t.json :image_urls
      t.timestamps
    end
    add_index :b2b_catalog_products, :shopify_product_id

    create_table :b2b_catalog_variants do |t|
      t.references :b2b_catalog_product, null: false, foreign_key: true
      t.string :sku, null: false
      t.string :size, null: false
      t.integer :position, null: false, default: 0
      t.integer :available, null: false, default: 0
      t.integer :availability, null: false, default: 2
      t.timestamps
    end
    add_index :b2b_catalog_variants, :sku

    create_table :b2b_catalog_orders do |t|
      t.references :b2b_catalog, null: false, foreign_key: true
      t.string :customer_name, null: false
      t.string :customer_registration
      t.references :client, foreign_key: true
      t.integer :status, null: false, default: 0
      t.references :b2b_order, foreign_key: true
      t.datetime :submitted_at
      t.string :last_edited_by
      t.string :edit_token, null: false
      t.timestamps
    end
    add_index :b2b_catalog_orders, [:b2b_catalog_id, :customer_registration], unique: true, name: 'index_b2b_catalog_orders_on_catalog_and_registration'
    add_index :b2b_catalog_orders, :edit_token, unique: true

    create_table :b2b_catalog_order_items do |t|
      t.references :b2b_catalog_order, null: false, foreign_key: true
      t.references :b2b_catalog_variant, null: false, foreign_key: true
      t.integer :quantity, null: false
      t.timestamps
    end
  end
end
```

> Unicidade por (catálogo, CNPJ) no banco: MySQL aceita vários NULL, então encomendas de catálogo por cliente sem CNPJ não colidem.

- [ ] **Step 4: Services CNPJ e NameSplitter**

`app/services/b2b_catalogs/cnpj.rb`:
```ruby
# CNPJ do lojista que se identifica no catálogo geral.
module B2bCatalogs
  module Cnpj
    module_function

    WEIGHTS_1 = [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2].freeze
    WEIGHTS_2 = [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2].freeze

    def digits(value) = value.to_s.gsub(/\D/, '')

    def valid?(value)
      numbers = digits(value)
      return false unless numbers.length == 14 && numbers.chars.uniq.size > 1

      base = numbers[0, 12].chars.map(&:to_i)
      first = check_digit(base, WEIGHTS_1)
      second = check_digit(base + [first], WEIGHTS_2)
      numbers[12, 2] == "#{first}#{second}"
    end

    def format(value)
      numbers = digits(value)
      return value.to_s unless numbers.length == 14

      numbers.sub(/(\d{2})(\d{3})(\d{3})(\d{4})(\d{2})/, '\1.\2.\3/\4-\5')
    end

    def check_digit(numbers, weights)
      rest = numbers.zip(weights).sum { |n, w| n * w } % 11
      rest < 2 ? 0 : 11 - rest
    end
  end
end
```

`app/services/b2b_catalogs/name_splitter.rb`:
```ruby
# Sugere Modelo e Cor a partir do nome do produto no Shopify (cada produto é uma cor e a cor é o fim
# do nome: "Legging Apex Seamless Ash"). Produtos que dividem o começo do nome com outro do catálogo
# formam o modelo; sem par, a última palavra vira a cor. Na tela os dois campos são editáveis.
module B2bCatalogs
  module NameSplitter
    module_function

    MIN_STYLE_WORDS = 2

    def split(names)
      words = names.uniq.index_with { |name| name.to_s.split }

      words.to_h do |name, parts|
        shared = words.except(name).values.map { |other| common_prefix(parts, other) }.max.to_i
        shared = [shared, parts.size - 1].min
        shared = parts.size - 1 if shared < MIN_STYLE_WORDS
        shared = parts.size if parts.size == 1

        [name, [parts.first(shared).join(' '), parts.drop(shared).join(' ')]]
      end
    end

    def common_prefix(a, b)
      a.zip(b).take_while { |x, y| x == y }.size
    end
  end
end
```

- [ ] **Step 5: Models**

`app/models/b2b_catalog.rb`:
```ruby
# Catálogo B2B: cores (B2bCatalogProduct) com seus tamanhos (B2bCatalogVariant), publicado num link
# público onde o lojista monta uma encomenda (B2bCatalogOrder). Sem preço.
class B2bCatalog < ApplicationRecord
  belongs_to :client, optional: true
  belongs_to :user
  has_many :products, -> { order(:position, :id) }, class_name: 'B2bCatalogProduct',
           dependent: :destroy, inverse_of: :catalog
  has_many :variants, through: :products
  has_many :catalog_orders, class_name: 'B2bCatalogOrder', dependent: :destroy, inverse_of: :catalog

  accepts_nested_attributes_for :products, allow_destroy: true

  enum :kind, { general: 0, client: 1 }, prefix: true
  enum :status, { active: 0, closed: 1 }

  KIND_LABELS = { 'general' => 'Geral', 'client' => 'Por cliente' }.freeze

  before_validation { self.client = nil if kind_general? }
  before_validation(on: :create) { self.public_token ||= self.class.new_token }

  validates :title, presence: true
  validates :client, presence: true, if: :kind_client?
  validates :public_token, presence: true, uniqueness: true

  def self.new_token = SecureRandom.urlsafe_base64(24)

  def regenerate_public_token!
    update!(public_token: self.class.new_token)
  end

  # [[modelo, [cores...]], ...] na ordem em que o modelo aparece pela primeira vez.
  def styles
    products.to_a.group_by(&:style_name).to_a
  end

  # Mensagem de erro se alguma quantidade não puder ser aceita; nil se está tudo certo.
  def quantity_error(quantities)
    by_id = variants.includes(:catalog_product).index_by(&:id)

    quantities.each do |variant_id, quantity|
      variant = by_id[variant_id.to_i]
      return 'Produto fora deste catálogo.' unless variant
      next unless quantity.to_i > [variant.available, 0].max

      product = variant.catalog_product
      return "#{product.style_name} #{product.color_name} #{variant.size}: quantidade acima do disponível.".squish
    end

    nil
  end
end
```

`app/models/b2b_catalog_product.rb`:
```ruby
# Uma cor do catálogo (= um produto do Shopify). As variantes (tamanhos) nascem dos SKUs escolhidos.
class B2bCatalogProduct < ApplicationRecord
  SIZE_ORDER = %w[PP XP P M G GG XG XGG EG EGG U UN].freeze

  belongs_to :catalog, class_name: 'B2bCatalog', foreign_key: :b2b_catalog_id, inverse_of: :products
  has_many :variants, -> { order(:position, :id) }, class_name: 'B2bCatalogVariant',
           foreign_key: :b2b_catalog_product_id, dependent: :destroy, inverse_of: :catalog_product

  attribute :skus

  validates :style_name, presence: true

  after_create :create_variants_from_skus

  def main_image = Array(image_urls).first

  private

  def create_variants_from_skus
    found = Product.where(sku: Array(skus).map { |s| s.to_s.strip }.reject(&:blank?)).to_a
    sorted = found.sort_by { |p| [SIZE_ORDER.index(p.option1.to_s.strip.upcase) || SIZE_ORDER.size, p.option1.to_s] }

    sorted.each_with_index do |product, index|
      variants.create!(sku: product.sku.to_s.upcase, size: product.option1.presence || product.sku, position: index)
    end

    update_columns(shopify_product_id: shopify_product_id.presence || found.filter_map(&:shopify_product_id).first,
                   image_urls: Array(image_urls).presence || found.filter_map(&:image_url).uniq.first(1))
  end
end
```

`app/models/b2b_catalog_variant.rb`:
```ruby
# Um tamanho de uma cor do catálogo. available é o disponível do Correios B2B − reservas da fila,
# gravado de hora em hora; a página pública só mostra o nível (availability).
class B2bCatalogVariant < ApplicationRecord
  LOW_STOCK = 5

  belongs_to :catalog_product, class_name: 'B2bCatalogProduct', foreign_key: :b2b_catalog_product_id, inverse_of: :variants
  has_many :order_items, class_name: 'B2bCatalogOrderItem', foreign_key: :b2b_catalog_variant_id,
           dependent: :destroy, inverse_of: :variant

  enum :availability, { available: 0, low: 1, sold_out: 2 }

  def self.availability_for(quantity)
    return :sold_out if quantity.to_i <= 0

    quantity.to_i <= LOW_STOCK ? :low : :available
  end
end
```

`app/models/b2b_catalog_order.rb`:
```ruby
# Encomenda do lojista num catálogo. Pode ser alterada (pelo lojista ou pelo Honey) até virar pedido.
class B2bCatalogOrder < ApplicationRecord
  belongs_to :catalog, class_name: 'B2bCatalog', foreign_key: :b2b_catalog_id, inverse_of: :catalog_orders
  belongs_to :client, optional: true
  belongs_to :b2b_order, optional: true
  has_many :items, class_name: 'B2bCatalogOrderItem', foreign_key: :b2b_catalog_order_id,
           dependent: :destroy, inverse_of: :catalog_order

  enum :status, { pending: 0, seen: 1, converted: 2 }

  STATUS_LABELS = { 'pending' => 'Nova', 'seen' => 'Vista', 'converted' => 'Convertida em pedido' }.freeze

  before_validation { self.customer_registration = B2bCatalogs::Cnpj.digits(customer_registration).presence }
  before_validation(on: :create) { self.edit_token ||= SecureRandom.urlsafe_base64(24) }

  validates :customer_name, presence: true
  validates :customer_registration, uniqueness: { scope: :b2b_catalog_id }, allow_nil: true
  validate :registration_must_be_a_valid_cnpj, if: -> { catalog&.kind_general? }

  def total_pieces = items.sum(&:quantity)

  def editable? = !converted? && catalog.active?

  def replace_items!(quantities, edited_by:)
    valid_ids = catalog.variants.pluck(:id)

    transaction do
      items.delete_all
      quantities.each do |variant_id, quantity|
        next unless quantity.to_i.positive? && valid_ids.include?(variant_id.to_i)

        items.create!(b2b_catalog_variant_id: variant_id.to_i, quantity: quantity.to_i)
      end
      update!(last_edited_by: edited_by)
    end
    items.reset
  end

  def convert!(order)
    update!(status: :converted, b2b_order: order)
  end

  def matching_client
    return client if client
    return nil if customer_registration.blank?

    Client.where("REPLACE(REPLACE(REPLACE(registration, '.', ''), '/', ''), '-', '') = ?", customer_registration).first
  end

  private

  def registration_must_be_a_valid_cnpj
    errors.add(:base, 'CNPJ inválido.') unless B2bCatalogs::Cnpj.valid?(customer_registration)
  end
end
```

`app/models/b2b_catalog_order_item.rb`:
```ruby
class B2bCatalogOrderItem < ApplicationRecord
  belongs_to :catalog_order, class_name: 'B2bCatalogOrder', foreign_key: :b2b_catalog_order_id, inverse_of: :items
  belongs_to :variant, class_name: 'B2bCatalogVariant', foreign_key: :b2b_catalog_variant_id, inverse_of: :order_items

  validates :quantity, numericality: { only_integer: true, greater_than: 0 }
end
```

- [ ] **Step 6: Schema e banco de teste**

Aplicar a migration num banco limpo (`chase_schema_cat`: `db:create db:schema:load db:migrate`), conferir `git diff db/schema.rb` (só as 5 tabelas + FKs), acertar charset `utf8mb4`/`utf8mb4_0900_ai_ci` das tabelas novas e criar um banco de teste novo com `newdb.sh`.

- [ ] **Step 7: Run tests to verify they pass**

Run: `... bin/rails test test/models/b2b_catalog_test.rb test/models/b2b_catalog_order_test.rb test/services/b2b_catalogs`
Expected: PASS.

---

### Task 2: Atualização de estoque e fotos (job de 1 hora)

**Files:**
- Create: `app/services/b2b_catalogs/shopify_images.rb`, `app/services/b2b_catalogs/refresher.rb`
- Create: `app/jobs/b2b_catalog_refresh_job.rb`, `lib/tasks/b2b_catalogs.rake`
- Test: `test/services/b2b_catalogs/refresher_test.rb`

**Interfaces:**
- Consumes: `B2bStockAvailability.correios_stocks(skus)`, `B2bStockAvailability.build(sku, stock)` (existentes), `Shopify::Products.client_shopify_rest`, models da Task 1.
- Produces: `B2bCatalogs::ShopifyImages.fetch(shopify_product_id) -> Array<String>`; `B2bCatalogs::Refresher.call(catalog_ids = nil)`; `B2bCatalogRefreshJob.perform_later(catalog_id = nil)`; rake `b2b_catalogs:refresh`.

- [ ] **Step 1: Write the failing test**

`test/services/b2b_catalogs/refresher_test.rb`:
```ruby
require 'test_helper'
require 'webmock/minitest'
require 'minitest/mock'

class B2bCatalogs::RefresherTest < ActiveSupport::TestCase
  def setup
    ENV['CORREIOS_ESTOQUE'] = 'https://correios-log.example.com/estoque/'
    ENV['CORREIOS_CARTAO_POSTAGEM_2'] = 'fake-cartao-2'
    ENV['TOKEN_LOG_PRODUCTION2'] = 'fake-token-2'
    user = User.create!(name: 'Refresh', email: 'refresh_cat@example.com', password: 'password123')
    Product.create!(sku: 'A-P', shopify_product_name: 'Top A Black', option1: 'P', shopify_product_id: '77')
    Product.create!(sku: 'A-M', shopify_product_name: 'Top A Black', option1: 'M', shopify_product_id: '77')
    @catalog = B2bCatalog.create!(title: 'Geral', user: user, products_attributes: [{ style_name: 'Top A', color_name: 'Black', skus: %w[A-P A-M] }])
    @closed = B2bCatalog.create!(title: 'Fechado', user: user, status: :closed, products_attributes: [{ style_name: 'Top A', color_name: 'Black', skus: %w[A-P] }])
  end

  def stub_stock(sku, disponivel, status: 200)
    stub_request(:get, "https://correios-log.example.com/estoque/#{sku}/estoque")
      .to_return(status:, body: { disponivel: disponivel }.to_json)
  end

  def variant(sku, catalog = @catalog) = catalog.variants.find_by(sku:)

  test 'writes available and level for every sku of active catalogs, minus the queue reservation' do
    stub_stock('A-P', 10)
    stub_stock('A-M', 0)
    StockReservation.create!(account: :b2b, tiny_order_id: '1', sku: 'A-P', quantity: 6)

    B2bCatalogs::ShopifyImages.stub(:fetch, []) { B2bCatalogs::Refresher.call }

    assert_equal [4, 'low'], [variant('A-P').available, variant('A-P').availability]
    assert_equal [0, 'sold_out'], [variant('A-M').available, variant('A-M').availability]
    assert @catalog.reload.stock_refreshed_at.present?
    assert_nil @closed.reload.stock_refreshed_at
  end

  test 'a Correios failure keeps the previous stock' do
    variant('A-P').update!(available: 8, availability: :available)
    stub_stock('A-P', 0, status: 500)
    stub_stock('A-M', 20)

    B2bCatalogs::ShopifyImages.stub(:fetch, []) { B2bCatalogs::Refresher.call }

    assert_equal 8, variant('A-P').available
    assert_equal 'available', variant('A-M').availability
  end

  test 'stores every Shopify image and keeps the old ones when Shopify returns nothing' do
    stub_stock('A-P', 1)
    stub_stock('A-M', 1)
    product = @catalog.products.first
    product.update!(image_urls: ['https://old.jpg'])

    B2bCatalogs::ShopifyImages.stub(:fetch, ['https://a.jpg', 'https://b.jpg']) { B2bCatalogs::Refresher.call }
    assert_equal ['https://a.jpg', 'https://b.jpg'], product.reload.image_urls

    B2bCatalogs::ShopifyImages.stub(:fetch, []) { B2bCatalogs::Refresher.call }
    assert_equal ['https://a.jpg', 'https://b.jpg'], product.reload.image_urls
  end

  test 'ShopifyImages returns the image srcs in position order and [] on failure' do
    body = { 'product' => { 'images' => [{ 'src' => 'https://2.jpg', 'position' => 2 }, { 'src' => 'https://1.jpg', 'position' => 1 }] } }
    client = Object.new
    client.define_singleton_method(:get) { |**| Struct.new(:body).new(body) }

    Shopify::Products.stub(:client_shopify_rest, client) do
      assert_equal ['https://1.jpg', 'https://2.jpg'], B2bCatalogs::ShopifyImages.fetch('77')
    end

    failing = Object.new
    failing.define_singleton_method(:get) { |**| raise StandardError, 'boom' }
    Shopify::Products.stub(:client_shopify_rest, failing) do
      assert_equal [], B2bCatalogs::ShopifyImages.fetch('77')
    end
  end

  test 'the job can refresh a single catalog' do
    stub_stock('A-P', 9)
    stub_stock('A-M', 9)

    B2bCatalogs::ShopifyImages.stub(:fetch, []) { B2bCatalogRefreshJob.perform_now(@catalog.id) }

    assert_equal 9, variant('A-P').available
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `... bin/rails test test/services/b2b_catalogs/refresher_test.rb`
Expected: ERROR `uninitialized constant B2bCatalogs::ShopifyImages`.

- [ ] **Step 3: Implement**

`app/services/b2b_catalogs/shopify_images.rb`:
```ruby
# Todas as fotos de um produto do Shopify, na ordem da loja. Falha devolve [] (quem chama mantém as fotos antigas).
module B2bCatalogs
  module ShopifyImages
    module_function

    PAUSE = Rails.env.test? ? 0 : 0.5 # limite da API REST do Shopify (2 req/s)

    def fetch(shopify_product_id)
      response = Shopify::Products.client_shopify_rest.get(path: "products/#{shopify_product_id}.json")
      images = Array(response.body.dig('product', 'images'))
      images.sort_by { |image| image['position'].to_i }.filter_map { |image| image['src'].presence }
    rescue StandardError => e
      Rails.logger.error "B2bCatalogs::ShopifyImages(#{shopify_product_id}): #{e.class} #{e.message}"
      []
    ensure
      sleep(PAUSE)
    end
  end
end
```

`app/services/b2b_catalogs/refresher.rb`:
```ruby
# Atualiza o disponível (Correios B2B − reservas da fila) e as fotos (Shopify) dos catálogos ativos.
# Roda de hora em hora (rake b2b_catalogs:refresh) e logo depois de salvar um catálogo.
module B2bCatalogs
  class Refresher
    def self.call(catalog_ids = nil) = new(catalog_ids).call

    def initialize(catalog_ids)
      scope = B2bCatalog.active
      scope = scope.where(id: catalog_ids) if catalog_ids.present?
      @catalog_ids = scope.pluck(:id)
    end

    def call
      return if @catalog_ids.empty?

      products = B2bCatalogProduct.where(b2b_catalog_id: @catalog_ids)
      refresh_stock(B2bCatalogVariant.where(b2b_catalog_product_id: products.select(:id)).distinct.pluck(:sku))
      refresh_images(products.where.not(shopify_product_id: [nil, '']).distinct.pluck(:shopify_product_id))
      B2bCatalog.where(id: @catalog_ids).update_all(stock_refreshed_at: Time.current)
    end

    private

    def refresh_stock(skus)
      stocks = B2bStockAvailability.correios_stocks(skus)

      skus.each do |sku|
        result = B2bStockAvailability.build(sku, stocks[sku])
        next if result.error?

        level = B2bCatalogVariant.availabilities[B2bCatalogVariant.availability_for(result.available)]
        B2bCatalogVariant.where(sku:).update_all(available: result.available, availability: level, updated_at: Time.current)
      end
    end

    def refresh_images(shopify_product_ids)
      shopify_product_ids.each do |shopify_product_id|
        urls = ShopifyImages.fetch(shopify_product_id)
        next if urls.empty?

        B2bCatalogProduct.where(shopify_product_id:).update_all(image_urls: urls.to_json, updated_at: Time.current)
      end
    end
  end
end
```

`app/jobs/b2b_catalog_refresh_job.rb`:
```ruby
class B2bCatalogRefreshJob < ActiveJob::Base
  queue_as :default

  def perform(catalog_id = nil)
    B2bCatalogs::Refresher.call(catalog_id.presence && [catalog_id])
  end
end
```

`lib/tasks/b2b_catalogs.rake`:
```ruby
namespace :b2b_catalogs do
  desc 'Atualiza estoque e fotos dos catálogos B2B ativos (agendar no Heroku Scheduler a cada 1 hora)'
  task refresh: :environment do
    B2bCatalogRefreshJob.perform_now
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `... bin/rails test test/services/b2b_catalogs/refresher_test.rb`
Expected: PASS (5 testes).

---

### Task 3: Montagem do catálogo no Honey

**Files:**
- Create: `app/controllers/b2b_catalogs_controller.rb`
- Create: `app/views/b2b_catalogs/index.html.erb`, `new.html.erb`, `edit.html.erb`, `_form.html.erb`, `show.html.erb`
- Create: `app/assets/stylesheets/admin/pages/_b2b_catalogs.scss` + import em `admin.scss`
- Modify: `config/routes.rb`, `app/models/screen.rb`, `app/views/layouts/partials/_sidebar.html.erb`
- Test: `test/controllers/b2b_catalogs_controller_test.rb`, `test/models/screen_test.rb`

**Interfaces:**
- Consumes: models (Task 1), `B2bCatalogRefreshJob` (Task 2), `B2bCatalogs::NameSplitter`.
- Produces: rotas `b2b_catalogs_path`, `new_b2b_catalog_path`, `b2b_catalog_path(c)`, `edit_b2b_catalog_path(c)`, `product_picker_b2b_catalogs_path`, `split_names_b2b_catalogs_path`, `toggle_status_b2b_catalog_path(c)`, `regenerate_token_b2b_catalog_path(c)`, `refresh_b2b_catalog_path(c)`, `pdf_b2b_catalog_path(c)`, `b2b_catalog_catalog_order_path(c, o)`, `edit_b2b_catalog_catalog_order_path(c, o)`, `public_catalog_url(token)`, `public_catalog_submit_path(token)`, `public_catalog_identify_path(token)`; chave de tela `b2b_catalogs`. (Rotas da Task 4/5/6 são declaradas aqui; os controllers delas vêm depois — as views da Task 3 só linkam para elas.)

- [ ] **Step 1: Write the failing tests**

`test/controllers/b2b_catalogs_controller_test.rb`:
```ruby
require 'test_helper'

class B2bCatalogsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  def setup
    @admin = User.create!(name: 'Admin Catálogo', email: 'admin_catalogo@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    Product.create!(sku: 'LEG-ASH-P', shopify_product_name: 'Legging Apex Seamless Ash', option1: 'P', shopify_product_id: '1')
    Product.create!(sku: 'LEG-ASH-M', shopify_product_name: 'Legging Apex Seamless Ash', option1: 'M', shopify_product_id: '1')
    Product.create!(sku: 'LEG-SKY-P', shopify_product_name: 'Legging Apex Seamless Sky', option1: 'P', shopify_product_id: '2')
    sign_in @admin
  end

  def catalog_params(**extra)
    { b2b_catalog: { title: 'Coleção Verão', kind: 'general', notes: 'Pedidos até sexta', products_attributes: {
      '0' => { style_name: 'Legging Apex Seamless', color_name: 'Ash', position: 0, skus: %w[LEG-ASH-P LEG-ASH-M] },
      '1' => { style_name: 'Legging Apex Seamless', color_name: 'Sky', position: 1, skus: %w[LEG-SKY-P] }
    } }.merge(extra) }
  end

  def create_catalog
    post b2b_catalogs_path, params: catalog_params
    B2bCatalog.last
  end

  test 'creates a catalog with colors and sizes and refreshes it right away' do
    assert_enqueued_with(job: B2bCatalogRefreshJob) do
      assert_difference('B2bCatalog.count', 1) { post b2b_catalogs_path, params: catalog_params }
    end
    catalog = B2bCatalog.last

    assert_redirected_to b2b_catalog_path(catalog)
    assert_equal %w[Ash Sky], catalog.products.map(&:color_name)
    assert_equal %w[P M], catalog.products.first.variants.map(&:size)
    assert_equal @admin, catalog.user
  end

  test 'a client catalog without client is refused' do
    post b2b_catalogs_path, params: catalog_params(kind: 'client')
    assert_response :unprocessable_entity
  end

  test 'product_picker groups variants by color' do
    get product_picker_b2b_catalogs_path, params: { query: 'apex' }
    products = JSON.parse(response.body)['products']

    assert_equal 2, products.size
    ash = products.find { |p| p['name'] == 'Legging Apex Seamless Ash' }
    assert_equal %w[LEG-ASH-P LEG-ASH-M].sort, ash['skus'].sort
  end

  test 'split_names suggests style and color' do
    post split_names_b2b_catalogs_path, params: { names: ['Legging Apex Seamless Ash', 'Legging Apex Seamless Sky'] }, as: :json
    assert_equal ['Legging Apex Seamless', 'Sky'], JSON.parse(response.body)['Legging Apex Seamless Sky']
  end

  test 'update renames, reorders and removes a color' do
    catalog = create_catalog
    ash, sky = catalog.products.to_a

    patch b2b_catalog_path(catalog), params: { b2b_catalog: { title: 'Verão 2', products_attributes: {
      '0' => { id: ash.id, _destroy: '1' },
      '1' => { id: sky.id, color_name: 'Céu', position: 0 }
    } } }

    assert_redirected_to b2b_catalog_path(catalog)
    assert_equal ['Céu'], catalog.reload.products.map(&:color_name)
    assert_equal 'Verão 2', catalog.title
  end

  test 'index shows the new orders badge and show lists the orders' do
    catalog = create_catalog
    catalog.catalog_orders.create!(customer_name: 'Loja Centro', customer_registration: '25.405.327/0001-74')

    get b2b_catalogs_path
    assert_select '.catalog-new-badge', text: /1/

    get b2b_catalog_path(catalog)
    assert_select '.catalog-order-row', text: /Loja Centro/
    assert_includes response.body, public_catalog_url(catalog.public_token)
  end

  test 'close, reopen and regenerate the link' do
    catalog = create_catalog
    old_token = catalog.public_token

    post toggle_status_b2b_catalog_path(catalog)
    assert catalog.reload.closed?
    post toggle_status_b2b_catalog_path(catalog)
    assert catalog.reload.active?

    post regenerate_token_b2b_catalog_path(catalog)
    refute_equal old_token, catalog.reload.public_token
  end

  test 'the edit form warns before removing a color that has items in orders' do
    catalog = create_catalog
    order = catalog.catalog_orders.create!(customer_name: 'Loja', customer_registration: '25.405.327/0001-74')
    order.replace_items!({ catalog.variants.first.id => 2 }, edited_by: 'customer')

    get edit_b2b_catalog_path(catalog)

    assert_select "[data-ordered-pieces='2']"
  end

  test 'users without the screen are redirected' do
    profile = Profile.create!(name: 'Sem Catalogo')
    user = User.create!(name: 'Sem Catalogo', email: 'sem_catalogo@example.com', password: 'password123')
    user.profiles << profile
    sign_in user

    get b2b_catalogs_path
    assert_redirected_to root_path
  end

  test 'sidebar shows Catálogos with the pending badge' do
    catalog = create_catalog
    catalog.catalog_orders.create!(customer_name: 'Loja', customer_registration: '25.405.327/0001-74')

    get b2b_orders_path

    assert_select "#pedidosB2bDropdown a[href='#{b2b_catalogs_path}']", text: /Catálogos/
    assert_select "#pedidosB2bDropdown a[href='#{b2b_catalogs_path}'] .nav-count-badge", text: '1'
  end
end
```

Adicionar em `test/models/screen_test.rb`:
```ruby
  test 'b2b catalogs screen belongs to the Pedidos B2B group' do
    assert_includes Screen::GROUPS['Pedidos B2B'], :b2b_catalogs
    assert_equal 'Catálogos B2B', Screen.label(:b2b_catalogs)
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `... bin/rails test test/controllers/b2b_catalogs_controller_test.rb test/models/screen_test.rb`
Expected: ERROR `undefined local variable or method 'b2b_catalogs_path'`.

- [ ] **Step 3: Screen, routes**

`app/models/screen.rb`: em `DEFINITIONS`, após `fiscal_notes:` → `b2b_catalogs: 'Catálogos B2B',`; em `GROUPS['Pedidos B2B']` → `%i[b2b_orders carriers companies fiscal_notes b2b_catalogs]`.

`config/routes.rb`, antes do comentário `# Reservas de estoque`:
```ruby
  # Catálogos B2B (montagem e encomendas no Honey) e a página pública do catálogo.
  resources :b2b_catalogs, except: :destroy do
    collection do
      get :product_picker
      post :split_names
    end
    member do
      post :toggle_status
      post :regenerate_token
      post :refresh
      get :pdf
    end
    resources :catalog_orders, controller: 'b2b_catalog_orders', only: %i[show edit update]
  end
  get 'catalogo/:token', to: 'public_catalogs#show', as: :public_catalog
  post 'catalogo/:token/encomenda', to: 'public_catalogs#submit', as: :public_catalog_submit, defaults: { format: :json }
  post 'catalogo/:token/identificar', to: 'public_catalogs#identify', as: :public_catalog_identify, defaults: { format: :json }
```

- [ ] **Step 4: Controller**

`app/controllers/b2b_catalogs_controller.rb`:
```ruby
# Montagem dos catálogos B2B e a lista de encomendas de cada um.
class B2bCatalogsController < ApplicationController
  guard_screen :b2b_catalogs
  before_action :set_catalog, only: %i[show edit update toggle_status regenerate_token refresh pdf]

  def index
    @catalogs = B2bCatalog.includes(:client).order(created_at: :desc)
    @order_counts = B2bCatalogOrder.group(:b2b_catalog_id).count
    @pending_counts = B2bCatalogOrder.pending.group(:b2b_catalog_id).count
  end

  def show
    @catalog_orders = @catalog.catalog_orders.includes(:items).order(:status, updated_at: :desc)
  end

  def new
    @catalog = B2bCatalog.new(kind: :general)
  end

  def create
    @catalog = B2bCatalog.new(catalog_params.merge(user: current_user))

    if @catalog.save
      B2bCatalogRefreshJob.perform_later(@catalog.id)
      redirect_to b2b_catalog_path(@catalog), notice: 'Catálogo criado. Estoque e fotos estão sendo atualizados.'
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @catalog.update(catalog_params)
      B2bCatalogRefreshJob.perform_later(@catalog.id)
      redirect_to b2b_catalog_path(@catalog), notice: 'Catálogo atualizado.'
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def toggle_status
    @catalog.update!(status: @catalog.active? ? :closed : :active)
    redirect_to b2b_catalog_path(@catalog), notice: @catalog.active? ? 'Catálogo reaberto.' : 'Catálogo encerrado: o link mostra que ele foi encerrado.'
  end

  def regenerate_token
    @catalog.regenerate_public_token!
    redirect_to b2b_catalog_path(@catalog), notice: 'Novo link gerado. O link antigo deixou de funcionar.'
  end

  def refresh
    B2bCatalogRefreshJob.perform_later(@catalog.id)
    redirect_to b2b_catalog_path(@catalog), notice: 'Atualização de estoque e fotos iniciada.'
  end

  def pdf
    pdf = B2bCatalogPdf.new(@catalog, public_url: public_catalog_url(@catalog.public_token))
    send_data pdf.render, filename: pdf.filename, type: 'application/pdf', disposition: 'attachment'
  end

  # Busca para o seletor: cada resultado é uma cor (produto do Shopify) com todos os seus SKUs.
  def product_picker
    tokens = params[:query].to_s.downcase.split(/\s+/).reject(&:blank?)
    products = if tokens.empty?
                 Product.none
               else
                 tokens.reduce(Product.all) do |scope, token|
                   scope.where('LOWER(sku) LIKE :q OR LOWER(shopify_product_name) LIKE :q', q: "%#{token}%")
                 end.limit(400)
               end

    groups = products.group_by { |p| p.shopify_product_id.presence || p.shopify_product_name.presence || p.sku }.values.first(40)
    render json: { products: groups.map { |variants| picker_entry(variants) } }
  end

  def split_names
    render json: B2bCatalogs::NameSplitter.split(Array(params[:names]).map(&:to_s))
  end

  private

  def set_catalog
    @catalog = B2bCatalog.find(params[:id])
  end

  def catalog_params
    params.require(:b2b_catalog).permit(:title, :kind, :client_id, :notes,
                                        products_attributes: [:id, :style_name, :color_name, :position, :_destroy, { skus: [] }])
  end

  def picker_entry(variants)
    sorted = variants.sort_by { |v| B2bCatalogProduct::SIZE_ORDER.index(v.option1.to_s.upcase) || 99 }
    { name: variants.first.shopify_product_name.presence || variants.first.sku,
      image_url: variants.find { |v| v.image_url.present? }&.image_url,
      skus: sorted.map(&:sku),
      sizes: sorted.map { |v| v.option1.presence || v.sku } }
  end
end
```

> `pdf` usa `B2bCatalogPdf` da Task 6; até lá a action existe mas não é exercitada por teste.

- [ ] **Step 5: Views**

`app/views/b2b_catalogs/index.html.erb`:
```erb
<% content_for :title, 'Catálogos B2B' %>

<div class="users-container catalogs-page">
  <div class="page-header">
    <div class="header-left">
      <h1 class="page-title"><i class="fas fa-book-open me-2"></i>Catálogos B2B</h1>
      <p class="page-subtitle">Monte catálogos, mande o link para os lojistas e transforme as encomendas em pedidos.</p>
    </div>
    <div class="header-actions">
      <%= link_to new_b2b_catalog_path, class: 'btn-export' do %><i class="fas fa-plus me-2"></i>Novo catálogo<% end %>
    </div>
  </div>

  <% if @catalogs.any? %>
    <div class="catalog-grid">
      <% @catalogs.each_with_index do |catalog, index| %>
        <%= link_to b2b_catalog_path(catalog), class: "catalog-card catalog-card--#{catalog.status}", style: "animation-delay: #{[index, 12].min * 40}ms" do %>
          <div class="catalog-card__top">
            <span class="catalog-card__kind"><%= B2bCatalog::KIND_LABELS[catalog.kind] %></span>
            <% if (pending = @pending_counts[catalog.id].to_i).positive? %>
              <span class="catalog-new-badge"><%= pending %> nova<%= 's' if pending > 1 %></span>
            <% end %>
          </div>
          <h3 class="catalog-card__title"><%= catalog.title %></h3>
          <div class="catalog-card__meta">
            <% if catalog.kind_client? %><span><i class="fas fa-store me-1"></i><%= catalog.client&.display_name %></span><% end %>
            <span><i class="fas fa-receipt me-1"></i><%= @order_counts[catalog.id].to_i %> encomenda(s)</span>
            <span class="catalog-status catalog-status--<%= catalog.status %>"><%= catalog.active? ? 'Ativo' : 'Encerrado' %></span>
          </div>
        <% end %>
      <% end %>
    </div>
  <% else %>
    <div class="table-card text-center text-muted-custom py-5">
      <i class="fas fa-book-open fa-2x mb-2"></i>
      <div>Nenhum catálogo ainda. Crie o primeiro e mande o link para os lojistas.</div>
    </div>
  <% end %>
</div>
```

`app/views/b2b_catalogs/new.html.erb`:
```erb
<% content_for :title, 'Novo catálogo' %>
<div class="users-container">
  <div class="page-header">
    <div class="header-left"><h1 class="page-title"><i class="fas fa-book-open me-2"></i>Novo catálogo</h1></div>
    <div class="header-actions"><%= link_to b2b_catalogs_path, class: 'btn-back' do %><i class="fas fa-arrow-left me-1"></i>Voltar<% end %></div>
  </div>
  <%= render 'form' %>
</div>
```

`app/views/b2b_catalogs/edit.html.erb`:
```erb
<% content_for :title, "Editar #{@catalog.title}" %>
<div class="users-container">
  <div class="page-header">
    <div class="header-left"><h1 class="page-title"><i class="fas fa-book-open me-2"></i><%= @catalog.title %></h1></div>
    <div class="header-actions"><%= link_to b2b_catalog_path(@catalog), class: 'btn-back' do %><i class="fas fa-arrow-left me-1"></i>Voltar<% end %></div>
  </div>
  <%= render 'form' %>
</div>
```

`app/views/b2b_catalogs/_form.html.erb`:
```erb
<% ordered_pieces = @catalog.persisted? ? B2bCatalogOrderItem.joins(:variant).where(b2b_catalog_variants: { b2b_catalog_product_id: @catalog.products.map(&:id) }).group('b2b_catalog_variants.b2b_catalog_product_id').sum(:quantity) : {} %>
<%= form_with model: @catalog, local: true, id: 'catalogForm' do |form| %>
  <% if @catalog.errors.any? %>
    <div class="form-error-box">
      <i class="fas fa-exclamation-triangle me-2"></i>
      <ul class="mb-0 mt-1"><% @catalog.errors.full_messages.each do |m| %><li><%= m %></li><% end %></ul>
    </div>
  <% end %>

  <div class="form-section">
    <div class="form-section-header"><h5 class="form-section-title"><i class="fas fa-tag me-2"></i>Dados do catálogo</h5></div>
    <div class="form-section-body">
      <div class="form-grid">
        <div class="form-col-6">
          <label class="field-label">Título</label>
          <%= form.text_field :title, class: 'field-input', placeholder: 'Ex.: Coleção Verão 2027', required: true %>
        </div>
        <div class="form-col-6">
          <label class="field-label">Tipo</label>
          <div class="catalog-kind-toggle">
            <% B2bCatalog::KIND_LABELS.each do |value, label| %>
              <label class="catalog-kind-option">
                <%= form.radio_button :kind, value, class: 'catalog-kind-radio' %>
                <span><i class="fas <%= value == 'general' ? 'fa-globe' : 'fa-store' %> me-1"></i><%= label %></span>
              </label>
            <% end %>
          </div>
        </div>
        <div class="form-col-6" id="catalogClientSection">
          <label class="field-label">Cliente</label>
          <%= form.collection_select :client_id, Client.order(:responsible_name), :id, :display_name, { include_blank: 'Selecione...' }, { class: 'field-input' } %>
        </div>
        <div class="form-col-12">
          <label class="field-label">Mensagem para o cliente (aparece no topo do catálogo)</label>
          <%= form.text_area :notes, class: 'field-input', rows: 2, placeholder: 'Ex.: Encomendas até sexta-feira. Envio em 10 dias.' %>
        </div>
      </div>
    </div>
  </div>

  <div class="form-section">
    <div class="form-section-header d-flex justify-content-between align-items-center">
      <h5 class="form-section-title"><i class="fas fa-palette me-2"></i>Produtos <small class="text-muted-custom">(cada linha é uma cor, com todos os tamanhos)</small></h5>
      <button type="button" class="btn-export" data-bs-toggle="modal" data-bs-target="#catalogPickerModal"><i class="fas fa-plus me-1"></i>Adicionar cores</button>
    </div>
    <div class="form-section-body">
      <div id="catalogProducts" class="catalog-builder">
        <% @catalog.products.each_with_index do |product, index| %>
          <div class="catalog-builder__row" data-ordered-pieces="<%= ordered_pieces[product.id].to_i %>">
            <%= hidden_field_tag "b2b_catalog[products_attributes][#{index}][id]", product.id %>
            <%= hidden_field_tag "b2b_catalog[products_attributes][#{index}][position]", product.position, class: 'catalog-position' %>
            <%= hidden_field_tag "b2b_catalog[products_attributes][#{index}][_destroy]", '0', class: 'catalog-destroy' %>
            <div class="catalog-builder__thumb"><% if product.main_image %><img src="<%= product.main_image %>" loading="lazy"><% else %><i class="fas fa-image"></i><% end %></div>
            <div class="catalog-builder__fields">
              <input type="text" class="field-input" name="b2b_catalog[products_attributes][<%= index %>][style_name]" value="<%= product.style_name %>" placeholder="Modelo">
              <input type="text" class="field-input" name="b2b_catalog[products_attributes][<%= index %>][color_name]" value="<%= product.color_name %>" placeholder="Cor">
            </div>
            <div class="catalog-builder__sizes"><% product.variants.each do |v| %><span class="catalog-size-chip catalog-size-chip--<%= v.availability %>"><%= v.size %></span><% end %></div>
            <div class="catalog-builder__actions">
              <button type="button" class="action-btn catalog-move" data-dir="-1" title="Subir"><i class="fas fa-arrow-up"></i></button>
              <button type="button" class="action-btn catalog-move" data-dir="1" title="Descer"><i class="fas fa-arrow-down"></i></button>
              <button type="button" class="action-btn action-btn--danger catalog-remove" title="Remover"><i class="fas fa-trash"></i></button>
            </div>
          </div>
        <% end %>
      </div>
      <div id="catalogEmpty" class="text-center text-muted-custom py-4 <%= 'd-none' if @catalog.products.any? %>">
        <i class="fas fa-palette fa-2x mb-2"></i><div>Adicione as cores que vão aparecer no catálogo.</div>
      </div>
    </div>
  </div>

  <div class="d-flex gap-2">
    <%= form.submit 'Salvar catálogo', class: 'btn-export' %>
  </div>
<% end %>

<div class="modal fade" id="catalogPickerModal" tabindex="-1" aria-hidden="true">
  <div class="modal-dialog modal-lg modal-dialog-scrollable">
    <div class="modal-content">
      <div class="modal-header">
        <h5 class="modal-title"><i class="fas fa-search me-2"></i>Adicionar cores</h5>
        <button type="button" class="btn-close btn-close-white" data-bs-dismiss="modal"></button>
      </div>
      <div class="modal-body">
        <input type="text" id="catalogPickerSearch" class="field-input mb-3" placeholder="Buscar por nome ou SKU (ex.: legging apex)">
        <div id="catalogPickerResults" class="catalog-picker-results"><div class="text-muted-custom text-center py-4">Digite algo para buscar.</div></div>
      </div>
    </div>
  </div>
</div>

<script>
document.addEventListener('DOMContentLoaded', function () {
  var container = document.getElementById('catalogProducts');
  var nextIndex = <%= @catalog.products.size + 1000 %>;
  var addedNames = {};

  function toggleClient() {
    var checked = document.querySelector('.catalog-kind-radio:checked');
    document.getElementById('catalogClientSection').style.display = checked && checked.value === 'client' ? '' : 'none';
  }
  document.querySelectorAll('.catalog-kind-radio').forEach(function (r) { r.addEventListener('change', toggleClient); });
  toggleClient();

  function visibleRows() {
    return Array.prototype.filter.call(container.querySelectorAll('.catalog-builder__row'), function (row) { return !row.classList.contains('d-none'); });
  }

  function renumber() {
    visibleRows().forEach(function (row, i) { row.querySelector('.catalog-position').value = i; });
    document.getElementById('catalogEmpty').classList.toggle('d-none', visibleRows().length > 0);
  }

  container.addEventListener('click', function (e) {
    var move = e.target.closest('.catalog-move');
    var remove = e.target.closest('.catalog-remove');
    if (move) {
      var row = move.closest('.catalog-builder__row');
      var rows = visibleRows();
      var idx = rows.indexOf(row) + parseInt(move.dataset.dir, 10);
      if (idx < 0 || idx >= rows.length) return;
      if (move.dataset.dir === '-1') container.insertBefore(row, rows[idx]); else container.insertBefore(rows[idx], row);
      row.classList.add('catalog-builder__row--moved');
      setTimeout(function () { row.classList.remove('catalog-builder__row--moved'); }, 400);
      renumber();
    }
    if (remove) {
      var target = remove.closest('.catalog-builder__row');
      var pieces = parseInt(target.dataset.orderedPieces || '0', 10);
      if (pieces > 0 && !confirm('Esta cor tem ' + pieces + ' peça(s) em encomendas. Removendo, esses itens saem das encomendas. Continuar?')) return;
      var destroy = target.querySelector('.catalog-destroy');
      if (destroy) { destroy.value = '1'; target.classList.add('d-none'); } else { target.remove(); }
      renumber();
    }
  });

  function escapeHtml(s) { var d = document.createElement('div'); d.textContent = s == null ? '' : s; return d.innerHTML; }

  // Sugere modelo/cor para as linhas novas, considerando todos os nomes já no catálogo.
  function suggestNames() {
    var rows = Array.prototype.filter.call(container.querySelectorAll('.catalog-builder__row[data-name]'), function (r) { return !r.dataset.suggested; });
    if (!rows.length) return;
    var names = Object.keys(addedNames).concat(Array.prototype.map.call(container.querySelectorAll('.catalog-builder__row'), function (r) {
      var s = r.querySelector('[name$="[style_name]"]').value, c = r.querySelector('[name$="[color_name]"]').value;
      return r.dataset.name || (s + ' ' + c).trim();
    }));
    fetch('<%= split_names_b2b_catalogs_path %>', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]').content },
      body: JSON.stringify({ names: names })
    }).then(function (r) { return r.json(); }).then(function (map) {
      rows.forEach(function (row) {
        var pair = map[row.dataset.name];
        if (!pair) return;
        row.querySelector('[name$="[style_name]"]').value = pair[0];
        row.querySelector('[name$="[color_name]"]').value = pair[1];
        row.dataset.suggested = '1';
      });
    });
  }

  function addColor(entry) {
    if (addedNames[entry.name]) return;
    addedNames[entry.name] = true;
    var i = nextIndex++;
    var base = 'b2b_catalog[products_attributes][' + i + ']';
    var row = document.createElement('div');
    row.className = 'catalog-builder__row catalog-builder__row--new';
    row.dataset.name = entry.name;
    row.dataset.orderedPieces = '0';
    row.innerHTML =
      '<input type="hidden" name="' + base + '[position]" class="catalog-position">' +
      entry.skus.map(function (sku) { return '<input type="hidden" name="' + base + '[skus][]" value="' + escapeHtml(sku) + '">'; }).join('') +
      '<div class="catalog-builder__thumb">' + (entry.image_url ? '<img src="' + escapeHtml(entry.image_url) + '" loading="lazy">' : '<i class="fas fa-image"></i>') + '</div>' +
      '<div class="catalog-builder__fields">' +
        '<input type="text" class="field-input" name="' + base + '[style_name]" value="' + escapeHtml(entry.name) + '" placeholder="Modelo">' +
        '<input type="text" class="field-input" name="' + base + '[color_name]" value="" placeholder="Cor">' +
      '</div>' +
      '<div class="catalog-builder__sizes">' + entry.sizes.map(function (s) { return '<span class="catalog-size-chip">' + escapeHtml(s) + '</span>'; }).join('') + '</div>' +
      '<div class="catalog-builder__actions">' +
        '<button type="button" class="action-btn catalog-move" data-dir="-1" title="Subir"><i class="fas fa-arrow-up"></i></button>' +
        '<button type="button" class="action-btn catalog-move" data-dir="1" title="Descer"><i class="fas fa-arrow-down"></i></button>' +
        '<button type="button" class="action-btn action-btn--danger catalog-remove" title="Remover"><i class="fas fa-trash"></i></button>' +
      '</div>';
    container.appendChild(row);
    renumber();
  }

  var searchTimer;
  document.getElementById('catalogPickerSearch').addEventListener('input', function (e) {
    clearTimeout(searchTimer);
    var q = e.target.value.trim();
    var box = document.getElementById('catalogPickerResults');
    if (!q) { box.innerHTML = '<div class="text-muted-custom text-center py-4">Digite algo para buscar.</div>'; return; }
    box.innerHTML = '<div class="text-muted-custom text-center py-4"><i class="fas fa-spinner fa-spin me-2"></i>Buscando...</div>';
    searchTimer = setTimeout(function () {
      fetch('<%= product_picker_b2b_catalogs_path %>?query=' + encodeURIComponent(q))
        .then(function (r) { return r.json(); })
        .then(function (data) {
          var products = data.products || [];
          if (!products.length) { box.innerHTML = '<div class="text-muted-custom text-center py-4">Nenhum produto encontrado.</div>'; return; }
          box.innerHTML = '';
          products.forEach(function (p) {
            var item = document.createElement('div');
            item.className = 'catalog-picker-item' + (addedNames[p.name] ? ' catalog-picker-item--added' : '');
            item.innerHTML =
              '<div class="catalog-builder__thumb">' + (p.image_url ? '<img src="' + escapeHtml(p.image_url) + '" loading="lazy">' : '<i class="fas fa-image"></i>') + '</div>' +
              '<div class="flex-grow-1"><div class="text-main fw-bold">' + escapeHtml(p.name) + '</div><div class="text-muted-custom small">' + p.sizes.map(escapeHtml).join(' · ') + '</div></div>' +
              '<button type="button" class="btn-export catalog-picker-add">' + (addedNames[p.name] ? '<i class="fas fa-check me-1"></i>Adicionada' : '<i class="fas fa-plus me-1"></i>Adicionar') + '</button>';
            item.querySelector('.catalog-picker-add').addEventListener('click', function (ev) {
              addColor(p);
              item.classList.add('catalog-picker-item--added');
              ev.currentTarget.innerHTML = '<i class="fas fa-check me-1"></i>Adicionada';
              suggestNames();
            });
            box.appendChild(item);
          });
        });
    }, 300);
  });

  document.getElementById('catalogForm').addEventListener('submit', renumber);
});
</script>
```

`app/views/b2b_catalogs/show.html.erb`:
```erb
<% content_for :title, @catalog.title %>
<% link = public_catalog_url(@catalog.public_token) %>

<div class="users-container catalogs-page">
  <div class="page-header">
    <div class="header-left">
      <h1 class="page-title"><i class="fas fa-book-open me-2"></i><%= @catalog.title %>
        <span class="catalog-status catalog-status--<%= @catalog.status %> ms-2"><%= @catalog.active? ? 'Ativo' : 'Encerrado' %></span>
      </h1>
      <p class="page-subtitle">
        <%= B2bCatalog::KIND_LABELS[@catalog.kind] %><%= " · #{@catalog.client&.display_name}" if @catalog.kind_client? %>
        · <%= @catalog.products.size %> cor(es)
        · estoque <%= @catalog.stock_refreshed_at ? "atualizado às #{l(@catalog.stock_refreshed_at, format: '%d/%m %H:%M')}" : 'ainda não atualizado' %>
      </p>
    </div>
    <div class="header-actions">
      <%= link_to b2b_catalogs_path, class: 'btn-back' do %><i class="fas fa-arrow-left me-1"></i>Voltar<% end %>
      <%= link_to edit_b2b_catalog_path(@catalog), class: 'btn-back' do %><i class="fas fa-pen me-1"></i>Editar<% end %>
      <%= link_to pdf_b2b_catalog_path(@catalog), class: 'btn-back' do %><i class="fas fa-file-pdf me-1"></i>PDF<% end %>
    </div>
  </div>

  <div class="catalog-share">
    <div class="catalog-share__link">
      <i class="fas fa-link"></i>
      <input type="text" readonly value="<%= link %>" id="catalogLink" class="field-input">
      <button type="button" class="btn-export" id="copyCatalogLink"><i class="fas fa-copy me-1"></i>Copiar link</button>
      <%= link_to link, target: '_blank', class: 'btn-back' do %><i class="fas fa-external-link-alt me-1"></i>Abrir<% end %>
    </div>
    <div class="catalog-share__actions">
      <%= button_to refresh_b2b_catalog_path(@catalog), class: 'btn-back', form: { class: 'd-inline' } do %><i class="fas fa-sync me-1"></i>Atualizar estoque<% end %>
      <%= button_to regenerate_token_b2b_catalog_path(@catalog), class: 'btn-back', form: { class: 'd-inline', onsubmit: "return confirm('O link atual deixa de funcionar. Gerar um novo?')" } do %><i class="fas fa-key me-1"></i>Novo link<% end %>
      <%= button_to toggle_status_b2b_catalog_path(@catalog), class: (@catalog.active? ? 'btn-back' : 'btn-export'), form: { class: 'd-inline' } do %>
        <i class="fas <%= @catalog.active? ? 'fa-lock' : 'fa-lock-open' %> me-1"></i><%= @catalog.active? ? 'Encerrar' : 'Reabrir' %>
      <% end %>
    </div>
  </div>

  <div class="table-card">
    <h5 class="px-3 pt-3 text-main"><i class="fas fa-receipt me-2"></i>Encomendas</h5>
    <% if @catalog_orders.any? %>
      <div class="table-responsive">
        <table class="orders-table">
          <thead><tr><th>Cliente</th><th>CNPJ</th><th>Atualizada</th><th class="text-end">Peças</th><th>Status</th><th>Alterada por</th><th class="text-end">Ações</th></tr></thead>
          <tbody>
            <% @catalog_orders.each do |order| %>
              <tr class="catalog-order-row catalog-order-row--<%= order.status %>">
                <td class="text-main"><% if order.pending? %><span class="catalog-dot"></span><% end %><%= order.customer_name %></td>
                <td class="text-muted-custom"><%= B2bCatalogs::Cnpj.format(order.customer_registration) %></td>
                <td class="text-muted-custom"><%= l(order.updated_at, format: '%d/%m %H:%M') %></td>
                <td class="text-end"><%= order.total_pieces %></td>
                <td><span class="catalog-order-status catalog-order-status--<%= order.status %>"><%= B2bCatalogOrder::STATUS_LABELS[order.status] %></span></td>
                <td class="text-muted-custom"><%= order.last_edited_by == 'customer' ? 'Cliente' : order.last_edited_by %></td>
                <td class="text-end"><%= link_to 'Abrir', b2b_catalog_catalog_order_path(@catalog, order), class: 'btn-back' %></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    <% else %>
      <div class="text-center text-muted-custom py-5"><i class="fas fa-inbox fa-2x mb-2"></i><div>Nenhuma encomenda ainda. Mande o link para os lojistas.</div></div>
    <% end %>
  </div>
</div>

<script>
  document.getElementById('copyCatalogLink').addEventListener('click', function (e) {
    var input = document.getElementById('catalogLink');
    input.select();
    (navigator.clipboard ? navigator.clipboard.writeText(input.value) : Promise.resolve(document.execCommand('copy'))).then(function () {
      e.currentTarget.innerHTML = '<i class="fas fa-check me-1"></i>Copiado!';
    });
  });
</script>
```

- [ ] **Step 6: Sidebar**

Em `app/views/layouts/partials/_sidebar.html.erb`, no grupo Pedidos B2B: acrescentar `|| current_user&.can_access_screen?('b2b_catalogs')` à condição do grupo e, após o bloco de `fiscal_notes`, dentro de `.dropdown-content`:
```erb
                <% if current_user&.can_access_screen?('b2b_catalogs') %>
                  <% pending_catalog_orders = B2bCatalogOrder.pending.count %>
                  <%= link_to b2b_catalogs_path, class: "dropdown-link #{'active' if controller_name.in?(%w[b2b_catalogs b2b_catalog_orders])}" do %>
                    <i class="fas fa-book-open"></i>
                    <span>Catálogos</span>
                    <% if pending_catalog_orders.positive? %><span class="nav-count-badge"><%= pending_catalog_orders %></span><% end %>
                  <% end %>
                <% end %>
```

- [ ] **Step 7: Styles**

`app/assets/stylesheets/admin/pages/_b2b_catalogs.scss` (+ `@import 'admin/pages/b2b_catalogs';` em `admin.scss`):
```scss
@import 'admin/variables';

@keyframes catalog-rise { from { opacity: 0; transform: translateY(8px); } to { opacity: 1; transform: none; } }
@keyframes catalog-pop { 0% { transform: scale(0.6); } 70% { transform: scale(1.15); } 100% { transform: scale(1); } }
@keyframes catalog-glow { 0%, 100% { box-shadow: 0 0 0 0 rgba($accent-blue-light, 0); } 50% { box-shadow: 0 0 0 6px rgba($accent-blue-light, 0.18); } }

.catalog-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(260px, 1fr));
  gap: 1rem;
}

.catalog-card {
  display: block;
  padding: 1.1rem 1.25rem;
  border: 1px solid $border-default;
  border-radius: $radius-lg;
  background: linear-gradient(160deg, $bg-surface, $bg-elevated);
  color: $text-secondary;
  text-decoration: none;
  animation: catalog-rise 0.4s ease-out both;
  transition: transform 0.2s ease, border-color 0.2s ease;

  &:hover { transform: translateY(-3px); border-color: $accent-blue; color: $text-secondary; }
  &--closed { opacity: 0.65; }

  &__top { display: flex; justify-content: space-between; align-items: center; }
  &__kind { font-size: 0.72rem; letter-spacing: 0.08em; text-transform: uppercase; color: $text-muted; }
  &__title { margin: 0.5rem 0 0.75rem; font-size: 1.15rem; font-weight: 800; color: $text-primary; }
  &__meta { display: flex; flex-wrap: wrap; gap: 0.75rem; font-size: 0.82rem; }
}

.catalog-new-badge, .nav-count-badge {
  padding: 0.05rem 0.55rem;
  border-radius: $radius-pill;
  background: $accent-blue;
  color: #fff;
  font-size: 0.72rem;
  font-weight: 700;
  animation: catalog-pop 0.4s ease-out, catalog-glow 2s ease-in-out 0.4s infinite;
}
.nav-count-badge { margin-left: auto; }

.catalog-status {
  padding: 0.05rem 0.6rem;
  border-radius: $radius-pill;
  font-size: 0.72rem;
  font-weight: 600;
  &--active { background: rgba($accent-green, 0.18); color: $accent-green-light; }
  &--closed { background: rgba($text-muted, 0.15); color: $text-muted; }
}

.catalog-kind-toggle { display: flex; gap: 0.5rem; }
.catalog-kind-option {
  cursor: pointer;
  input { display: none; }
  span { display: inline-block; padding: 0.45rem 0.9rem; border: 1px solid $border-muted; border-radius: $radius-pill; color: $text-muted; transition: all 0.2s ease; }
  input:checked + span { border-color: $accent-blue; background: rgba($accent-blue, 0.15); color: $accent-blue-lighter; }
}

.catalog-builder {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;

  &__row {
    display: grid;
    grid-template-columns: 56px minmax(0, 2fr) minmax(0, 1fr) auto;
    gap: 0.75rem;
    align-items: center;
    padding: 0.5rem 0.75rem;
    border: 1px solid $border-default;
    border-radius: $radius-md;
    background: $bg-canvas;
    transition: transform 0.25s ease, border-color 0.25s ease;

    &--new { animation: catalog-rise 0.35s ease-out; border-color: rgba($accent-blue, 0.5); }
    &--moved { border-color: $accent-blue-light; transform: scale(1.01); }
  }

  &__thumb {
    width: 56px; height: 70px;
    display: flex; align-items: center; justify-content: center;
    border-radius: $radius-sm; overflow: hidden; background: $bg-elevated; color: $text-faint;
    img { width: 100%; height: 100%; object-fit: cover; }
  }
  &__fields { display: grid; grid-template-columns: 2fr 1fr; gap: 0.5rem; }
  &__sizes { display: flex; flex-wrap: wrap; gap: 0.3rem; }
  &__actions { display: flex; gap: 0.3rem; }
}

.catalog-size-chip {
  padding: 0.1rem 0.5rem;
  border: 1px solid $border-muted;
  border-radius: $radius-sm;
  font-size: 0.75rem;
  color: $text-secondary;
  &--low { border-color: $accent-yellow; color: $accent-yellow; }
  &--sold_out { color: $text-faint; text-decoration: line-through; }
}

.catalog-picker-results { display: flex; flex-direction: column; gap: 0.5rem; }
.catalog-picker-item {
  display: flex; align-items: center; gap: 0.75rem;
  padding: 0.5rem; border-radius: $radius-md; border: 1px solid $border-default;
  animation: catalog-rise 0.25s ease-out both;
  &--added { border-color: rgba($accent-green, 0.6); }
}

.catalog-share {
  display: flex; flex-wrap: wrap; gap: 0.75rem; justify-content: space-between; align-items: center;
  margin-bottom: 1.25rem; padding: 1rem 1.25rem;
  border: 1px solid $border-default; border-radius: $radius-lg;
  background: linear-gradient(90deg, rgba($accent-blue, 0.12), rgba($accent-green, 0.06));
  &__link { display: flex; align-items: center; gap: 0.5rem; flex: 1 1 420px; i { color: $accent-blue-light; } input { flex: 1; } }
  &__actions { display: flex; gap: 0.5rem; flex-wrap: wrap; }
}

.catalog-dot {
  display: inline-block; width: 8px; height: 8px; margin-right: 0.5rem; border-radius: 50%;
  background: $accent-blue-light; animation: catalog-glow 2s ease-in-out infinite;
}
.catalog-order-row--pending td { background: rgba($accent-blue, 0.06); }
.catalog-order-status {
  padding: 0.05rem 0.6rem; border-radius: $radius-pill; font-size: 0.75rem; font-weight: 600;
  &--pending { background: rgba($accent-blue, 0.2); color: $accent-blue-lighter; }
  &--seen { background: rgba($text-muted, 0.15); color: $text-secondary; }
  &--converted { background: rgba($accent-green, 0.18); color: $accent-green-light; }
}

@media (max-width: 768px) {
  .catalog-builder__row { grid-template-columns: 56px 1fr; }
  .catalog-builder__fields { grid-template-columns: 1fr; }
}
```

- [ ] **Step 8: Run tests**

Run: `... bin/rails test test/controllers/b2b_catalogs_controller_test.rb test/models/screen_test.rb test/controllers/sidebar_test.rb`
Expected: PASS. (Os links para `b2b_catalog_catalog_order_path` funcionam porque a rota existe; o controller vem na Task 4.)

---

### Task 4: Encomendas no Honey (ver, alterar, criar pedido)

**Files:**
- Create: `app/controllers/b2b_catalog_orders_controller.rb`, `app/views/b2b_catalog_orders/show.html.erb`, `app/views/b2b_catalog_orders/edit.html.erb`
- Modify: `app/controllers/b2b_orders_controller.rb` (`new`, `create`), `app/views/b2b_orders/_form.html.erb` (campo oculto `catalog_order_id`)
- Test: `test/controllers/b2b_catalog_orders_controller_test.rb`

**Interfaces:**
- Consumes: models (Task 1), rotas (Task 3), `B2bOrdersController#suggested_price_for(product)` (existente, privado).
- Produces: `new_b2b_order_path(catalog_order_id:)` pré-preenchido; param `catalog_order_id` no create converte a encomenda.

- [ ] **Step 1: Write the failing tests**

`test/controllers/b2b_catalog_orders_controller_test.rb`:
```ruby
require 'test_helper'
require 'webmock/minitest'

class B2bCatalogOrdersControllerTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(name: 'Ana Admin', email: 'ana_catalog_orders@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    Product.create!(sku: 'A-P', shopify_product_name: 'Top A Black', option1: 'P', price: '100')
    Product.create!(sku: 'A-M', shopify_product_name: 'Top A Black', option1: 'M', price: '100')
    @catalog = B2bCatalog.create!(title: 'Geral', user: @admin, products_attributes: [{ style_name: 'Top A', color_name: 'Black', skus: %w[A-P A-M] }])
    @p, @m = @catalog.variants.to_a
    @client = Client.create!(responsible_name: 'Loja Centro', registration: '25.405.327/0001-74')
    @order = @catalog.catalog_orders.create!(customer_name: 'Loja Centro', customer_registration: '25405327000174')
    @order.replace_items!({ @p.id => 2, @m.id => 3 }, edited_by: 'customer')
    ENV['TOKEN_TINY2_PRODUCTION'] = 'fake-token-tiny2'
    sign_in @admin
  end

  test 'opening a new order marks it as seen and shows its items' do
    get b2b_catalog_catalog_order_path(@catalog, @order)

    assert_response :success
    assert @order.reload.seen?
    assert_select '.catalog-order-item', count: 2
    assert_select '.catalog-order-item', text: /Top A.*Black.*P.*2/m
  end

  test 'Honey can change the order and it records who changed it' do
    patch b2b_catalog_catalog_order_path(@catalog, @order), params: { quantities: { @p.id.to_s => '5', @m.id.to_s => '0' } }

    assert_redirected_to b2b_catalog_catalog_order_path(@catalog, @order)
    assert_equal [[@p.id, 5]], @order.items.reload.pluck(:b2b_catalog_variant_id, :quantity)
    assert_equal 'Ana Admin', @order.reload.last_edited_by
  end

  test 'a converted order cannot be edited' do
    @order.update!(status: :converted)

    patch b2b_catalog_catalog_order_path(@catalog, @order), params: { quantities: { @p.id.to_s => '9' } }

    assert_match(/já virou pedido/, flash[:alert])
    assert_equal 2, @order.items.find_by(b2b_catalog_variant_id: @p.id).quantity
  end

  test 'create order opens the B2B order form filled with the items and the matching client' do
    get new_b2b_order_path(catalog_order_id: @order.id)

    assert_response :success
    assert_select "input[name$='[sku]'][value='A-P']"
    assert_select "input[name$='[quantity]'][value='3']"
    assert_select "input[name$='[price]'][value='40.0']"
    assert_select "#clientIdField[value='#{@client.id}']"
    assert_select "input[name='catalog_order_id'][value='#{@order.id}']"
  end

  test 'saving the B2B order converts the catalog order' do
    stub_request(:get, %r{formas\.envio}).to_return(body: { retorno: { status: 'OK', registros: [] } }.to_json)
    stub_request(:post, 'https://api.tiny.com.br/api2/pedido.incluir.php')
      .to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '1', numero: '2' } } } }.to_json)

    assert_difference('B2bOrder.count', 1) do
      post b2b_orders_path, params: { catalog_order_id: @order.id, b2b_order: { client_id: @client.id, b2b_order_items_attributes: {
        '0' => { sku: 'A-P', name: 'Top A Black - P', quantity: 2, price: 40 }
      } } }
    end

    assert @order.reload.converted?
    assert_equal B2bOrder.last, @order.b2b_order
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `... bin/rails test test/controllers/b2b_catalog_orders_controller_test.rb`
Expected: ERROR (`uninitialized constant B2bCatalogOrdersController`) e falhas no formulário.

- [ ] **Step 3: Controller e views das encomendas**

`app/controllers/b2b_catalog_orders_controller.rb`:
```ruby
# Encomendas de um catálogo vistas pelo Honey: abrir (marca como vista), alterar e virar pedido.
class B2bCatalogOrdersController < ApplicationController
  guard_screen :b2b_catalogs
  before_action :set_order

  def show
    @catalog_order.update!(status: :seen) if @catalog_order.pending?
    @quantities = @catalog_order.items.to_h { |item| [item.b2b_catalog_variant_id, item.quantity] }
  end

  def edit
    @quantities = @catalog_order.items.to_h { |item| [item.b2b_catalog_variant_id, item.quantity] }
  end

  def update
    if @catalog_order.converted?
      redirect_to b2b_catalog_catalog_order_path(@catalog, @catalog_order), alert: 'Esta encomenda já virou pedido e não pode mais ser alterada.'
      return
    end

    quantities = params.fetch(:quantities, {}).to_unsafe_h.transform_keys(&:to_i).transform_values(&:to_i)
    @catalog_order.replace_items!(quantities, edited_by: current_user.name)
    redirect_to b2b_catalog_catalog_order_path(@catalog, @catalog_order), notice: 'Encomenda alterada. O cliente vê a nova versão no link.'
  end

  private

  def set_order
    @catalog = B2bCatalog.find(params[:b2b_catalog_id])
    @catalog_order = @catalog.catalog_orders.find(params[:id])
  end
end
```

`app/views/b2b_catalog_orders/show.html.erb`:
```erb
<% content_for :title, "Encomenda — #{@catalog_order.customer_name}" %>

<div class="users-container catalogs-page">
  <div class="page-header">
    <div class="header-left">
      <h1 class="page-title"><i class="fas fa-receipt me-2"></i><%= @catalog_order.customer_name %>
        <span class="catalog-order-status catalog-order-status--<%= @catalog_order.status %> ms-2"><%= B2bCatalogOrder::STATUS_LABELS[@catalog_order.status] %></span>
      </h1>
      <p class="page-subtitle">
        <%= @catalog.title %> · CNPJ <%= B2bCatalogs::Cnpj.format(@catalog_order.customer_registration).presence || '—' %>
        · <%= @catalog_order.total_pieces %> peça(s)
        · alterada por <%= @catalog_order.last_edited_by == 'customer' ? 'Cliente' : @catalog_order.last_edited_by %>
        em <%= l(@catalog_order.updated_at, format: '%d/%m %H:%M') %>
      </p>
    </div>
    <div class="header-actions">
      <%= link_to b2b_catalog_path(@catalog), class: 'btn-back' do %><i class="fas fa-arrow-left me-1"></i>Voltar<% end %>
      <% if @catalog_order.converted? %>
        <%= link_to edit_b2b_order_path(@catalog_order.b2b_order), class: 'btn-export' do %><i class="fas fa-file-invoice-dollar me-1"></i>Ver pedido #<%= @catalog_order.b2b_order_id %><% end if @catalog_order.b2b_order %>
      <% else %>
        <%= link_to edit_b2b_catalog_catalog_order_path(@catalog, @catalog_order), class: 'btn-back' do %><i class="fas fa-pen me-1"></i>Alterar<% end %>
        <%= link_to new_b2b_order_path(catalog_order_id: @catalog_order.id), class: 'btn-export' do %><i class="fas fa-magic me-1"></i>Criar pedido<% end %>
      <% end %>
    </div>
  </div>

  <div class="table-card catalog-order-sheet">
    <% @catalog.styles.each do |style, colors| %>
      <% chosen = colors.flat_map { |c| c.variants.select { |v| @quantities[v.id].to_i.positive? }.map { |v| [c, v] } } %>
      <% next if chosen.empty? %>
      <div class="catalog-order-style">
        <h6 class="catalog-order-style__name"><%= style %></h6>
        <% chosen.group_by(&:first).each do |color, pairs| %>
          <div class="catalog-order-color">
            <div class="catalog-builder__thumb"><% if color.main_image %><img src="<%= color.main_image %>" loading="lazy"><% else %><i class="fas fa-image"></i><% end %></div>
            <div class="catalog-order-color__name"><%= color.color_name %></div>
            <div class="catalog-order-color__sizes">
              <% pairs.each do |_, variant| %>
                <span class="catalog-order-item"><%= style %> <%= color.color_name %> <b><%= variant.size %></b> × <%= @quantities[variant.id] %></span>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    <% end %>
    <% if @catalog_order.items.empty? %>
      <div class="text-center text-muted-custom py-5">Encomenda sem itens.</div>
    <% end %>
  </div>
</div>
```

`app/views/b2b_catalog_orders/edit.html.erb`:
```erb
<% content_for :title, "Alterar encomenda — #{@catalog_order.customer_name}" %>

<div class="users-container catalogs-page">
  <div class="page-header">
    <div class="header-left">
      <h1 class="page-title"><i class="fas fa-pen me-2"></i>Alterar encomenda de <%= @catalog_order.customer_name %></h1>
      <p class="page-subtitle">Mude as quantidades (0 tira o item). O cliente vê a nova versão no link.</p>
    </div>
    <div class="header-actions"><%= link_to b2b_catalog_catalog_order_path(@catalog, @catalog_order), class: 'btn-back' do %><i class="fas fa-arrow-left me-1"></i>Voltar<% end %></div>
  </div>

  <%= form_with url: b2b_catalog_catalog_order_path(@catalog, @catalog_order), method: :patch, local: true do %>
    <div class="table-card catalog-order-sheet">
      <% @catalog.styles.each do |style, colors| %>
        <div class="catalog-order-style">
          <h6 class="catalog-order-style__name"><%= style %></h6>
          <% colors.each do |color| %>
            <div class="catalog-order-color">
              <div class="catalog-builder__thumb"><% if color.main_image %><img src="<%= color.main_image %>" loading="lazy"><% else %><i class="fas fa-image"></i><% end %></div>
              <div class="catalog-order-color__name"><%= color.color_name %></div>
              <div class="catalog-order-color__sizes">
                <% color.variants.each do |variant| %>
                  <label class="catalog-qty catalog-qty--<%= variant.availability %>">
                    <span><%= variant.size %></span>
                    <%= number_field_tag "quantities[#{variant.id}]", @quantities[variant.id].to_i, min: 0, class: 'field-input' %>
                  </label>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
      <div class="p-3"><button type="submit" class="btn-export"><i class="fas fa-save me-1"></i>Salvar alterações</button></div>
    </div>
  <% end %>
</div>
```

Acrescentar em `_b2b_catalogs.scss`:
```scss
.catalog-order-sheet { padding: 0.5rem 0; }
.catalog-order-style {
  padding: 0.75rem 1.25rem;
  border-bottom: 1px solid $border-default;
  animation: catalog-rise 0.35s ease-out both;
  &:last-child { border-bottom: none; }
  &__name { margin-bottom: 0.6rem; font-weight: 800; letter-spacing: 0.04em; text-transform: uppercase; color: $text-primary; }
}
.catalog-order-color {
  display: grid; grid-template-columns: 56px 140px 1fr; gap: 0.75rem; align-items: center; padding: 0.35rem 0;
  &__name { font-weight: 600; color: $text-secondary; }
  &__sizes { display: flex; flex-wrap: wrap; gap: 0.4rem; }
}
.catalog-order-item {
  padding: 0.2rem 0.6rem; border-radius: $radius-pill; background: rgba($accent-blue, 0.12); color: $text-secondary; font-size: 0.82rem;
  b { color: $text-primary; }
}
.catalog-qty {
  display: flex; flex-direction: column; align-items: center; gap: 0.2rem; width: 64px;
  span { font-size: 0.75rem; font-weight: 700; color: $text-muted; }
  input { text-align: center; padding: 0.3rem; }
  &--sold_out span { text-decoration: line-through; }
  &--low span { color: $accent-yellow; }
}
@media (max-width: 768px) { .catalog-order-color { grid-template-columns: 56px 1fr; } .catalog-order-color__sizes { grid-column: 1 / -1; } }
```

- [ ] **Step 4: Pré-preencher e converter no pedido B2B**

Em `app/controllers/b2b_orders_controller.rb`:

`new` passa a ser:
```ruby
  def new
    @b2b_order = B2bOrder.new(kind: order_kind, price_list: price_list_for(order_kind))
    prefill_from_catalog_order(@b2b_order) if order_kind == 'sale' && params[:catalog_order_id].present?
  end
```

Em `create`, logo após `if @b2b_order.valid? && stock_available?(@b2b_order) && @b2b_order.save`:
```ruby
      link_catalog_order(@b2b_order)
```

Na seção `private`:
```ruby
  # Pedido de venda a partir de uma encomenda de catálogo: itens, quantidades, cliente (pelo CNPJ) e
  # preço sugerido de sempre. O usuário completa o resto e salva.
  def prefill_from_catalog_order(order)
    catalog_order = B2bCatalogOrder.includes(:catalog, items: { variant: :catalog_product }).find_by(id: params[:catalog_order_id])
    return unless catalog_order && !catalog_order.converted?

    order.client = catalog_order.matching_client
    order.notes = "Encomenda do catálogo \"#{catalog_order.catalog.title}\" — #{catalog_order.customer_name}"
    products = Product.where(sku: catalog_order.items.map { |item| item.variant.sku }).index_by { |p| p.sku.to_s.upcase }

    catalog_order.items.sort_by { |item| [item.variant.catalog_product.position, item.variant.position] }.each do |item|
      variant = item.variant
      product = products[variant.sku]
      name = product&.shopify_product_name.present? ? "#{product.shopify_product_name} - #{variant.size}" : "#{variant.catalog_product.style_name} #{variant.catalog_product.color_name} #{variant.size}".squish
      order.b2b_order_items.build(sku: variant.sku, name:, quantity: item.quantity, price: suggested_price_for(product) || 0)
    end
  end

  def link_catalog_order(order)
    return if params[:catalog_order_id].blank?

    B2bCatalogOrder.find_by(id: params[:catalog_order_id])&.convert!(order)
  end
```

Em `app/views/b2b_orders/_form.html.erb`, logo após a abertura do `form_with` (antes do bloco de erros):
```erb
  <%= hidden_field_tag :catalog_order_id, params[:catalog_order_id] if params[:catalog_order_id].present? %>
```

- [ ] **Step 5: Run tests**

Run: `... bin/rails test test/controllers/b2b_catalog_orders_controller_test.rb test/controllers/b2b_orders_controller_test.rb test/controllers/b2b_orders_stock_reservation_test.rb`
Expected: PASS.

---

### Task 5: Página pública do catálogo

**Files:**
- Create: `app/controllers/public_catalogs_controller.rb`
- Create: `app/services/b2b_catalogs/public_payload.rb`
- Create: `app/views/layouts/public_catalog.html.erb`, `app/views/public_catalogs/show.html.erb`, `app/views/public_catalogs/unavailable.html.erb`
- Create: `app/assets/stylesheets/public_catalog.scss`
- Test: `test/controllers/public_catalogs_controller_test.rb`

**Interfaces:**
- Consumes: models (Task 1), rotas públicas (Task 3).
- Produces: `B2bCatalogs::PublicPayload.new(catalog, order).as_json -> Hash` (`catalog`, `order`, `styles`); endpoints JSON `submit` / `identify` com `{ ok:, error:, order: }`; cookie assinado `catalog_order_<catalog_id>` = `edit_token`.

- [ ] **Step 1: Write the failing tests**

`test/controllers/public_catalogs_controller_test.rb`:
```ruby
require 'test_helper'

class PublicCatalogsControllerTest < ActionDispatch::IntegrationTest
  def setup
    user = User.create!(name: 'Dono', email: 'dono_publico@example.com', password: 'password123')
    Product.create!(sku: 'A-P', shopify_product_name: 'Top A Black', option1: 'P', image_url: 'https://img/a.jpg')
    Product.create!(sku: 'A-M', shopify_product_name: 'Top A Black', option1: 'M')
    @catalog = B2bCatalog.create!(title: 'Coleção Verão', notes: 'Até sexta', user: user,
                                  products_attributes: [{ style_name: 'Top A', color_name: 'Black', skus: %w[A-P A-M] }])
    @p, @m = @catalog.variants.to_a
    @p.update!(available: 3, availability: :low)
    @m.update!(available: 0, availability: :sold_out)
    @client = Client.create!(responsible_name: 'Loja Centro', registration: '25.405.327/0001-74')
  end

  def submit(catalog = @catalog, **body)
    post public_catalog_submit_path(catalog.public_token), params: body, as: :json
    JSON.parse(response.body)
  end

  test 'shows the catalog without login, with levels and without prices or exact stock' do
    get public_catalog_path(@catalog.public_token)

    assert_response :success
    assert_select 'h1', text: /Coleção Verão/
    payload = JSON.parse(css_select('#catalogData').first.text)
    variant = payload['styles'].first['colors'].first['variants'].first
    assert_equal 'low', variant['availability']
    refute_match(/preço|R\$/i, response.body)
  end

  test 'unknown token is a 404' do
    get public_catalog_path('nope')
    assert_response :not_found
  end

  test 'a general catalog order needs name and a valid CNPJ' do
    json = submit(customer_name: 'Loja', customer_registration: '25.405.327/0001-75', quantities: { @p.id => 1 })
    refute json['ok']
    assert_match(/CNPJ inválido/, json['error'])
  end

  test 'submitting creates the order, sets the cookie and the same CNPJ updates it' do
    json = submit(customer_name: 'Loja Centro', customer_registration: '25.405.327/0001-74', quantities: { @p.id => 2 })

    assert json['ok']
    order = @catalog.catalog_orders.last
    assert_equal [[@p.id, 2]], order.items.pluck(:b2b_catalog_variant_id, :quantity)
    assert order.pending?
    assert_equal 'customer', order.last_edited_by
    assert cookies["catalog_order_#{@catalog.id}"].present?

    order.update!(status: :seen)
    assert_no_difference('B2bCatalogOrder.count') do
      submit(customer_name: 'Loja Centro', customer_registration: '25405327000174', quantities: { @p.id => 3 })
    end
    assert_equal 3, order.items.reload.first.quantity
    assert order.reload.pending?
  end

  test 'quantities above available or from another catalog are refused' do
    assert_match(/acima do disponível/, submit(customer_name: 'L', customer_registration: '25405327000174', quantities: { @p.id => 4 })['error'])
    assert_match(/acima do disponível/, submit(customer_name: 'L', customer_registration: '25405327000174', quantities: { @m.id => 1 })['error'])
    assert_match(/fora deste catálogo/, submit(customer_name: 'L', customer_registration: '25405327000174', quantities: { 999_999 => 1 })['error'])
    assert_match(/pelo menos uma peça/, submit(customer_name: 'L', customer_registration: '25405327000174', quantities: { @p.id => 0 })['error'])
    assert_equal 0, B2bCatalogOrder.count
  end

  test 'a closed catalog or a converted order cannot be changed' do
    submit(customer_name: 'L', customer_registration: '25405327000174', quantities: { @p.id => 1 })
    @catalog.catalog_orders.last.update!(status: :converted)
    assert_match(/em andamento/, submit(customer_name: 'L', customer_registration: '25405327000174', quantities: { @p.id => 2 })['error'])

    @catalog.update!(status: :closed)
    assert_match(/encerrado/, submit(customer_name: 'Outra', customer_registration: '11.222.333/0001-81', quantities: { @p.id => 1 })['error'])
    get public_catalog_path(@catalog.public_token)
    assert_select '.pc-closed', text: /encerrado/i
  end

  test 'identify by CNPJ loads the existing order' do
    submit(customer_name: 'Loja Centro', customer_registration: '25405327000174', quantities: { @p.id => 2 })
    cookies.delete("catalog_order_#{@catalog.id}")

    post public_catalog_identify_path(@catalog.public_token), params: { customer_registration: '25.405.327/0001-74' }, as: :json
    json = JSON.parse(response.body)

    assert json['ok']
    assert_equal 'Loja Centro', json['order']['customer_name']
    assert_equal({ @p.id.to_s => 2 }, json['order']['quantities'])
  end

  test 'the cookie reopens the order on the next visit' do
    submit(customer_name: 'Loja Centro', customer_registration: '25405327000174', quantities: { @p.id => 2 })

    get public_catalog_path(@catalog.public_token)
    payload = JSON.parse(css_select('#catalogData').first.text)

    assert_equal 'Loja Centro', payload['order']['customer_name']
    assert_equal({ @p.id.to_s => 2 }, payload['order']['quantities'])
  end

  test 'a client catalog needs no identification and keeps a single order' do
    catalog = B2bCatalog.create!(title: 'Só Loja Centro', kind: :client, client: @client, user: @catalog.user,
                                 products_attributes: [{ style_name: 'Top A', color_name: 'Black', skus: %w[A-P] }])
    variant = catalog.variants.first
    variant.update!(available: 10, availability: :available)

    get public_catalog_path(catalog.public_token)
    payload = JSON.parse(css_select('#catalogData').first.text)
    assert_equal 'Loja Centro', payload['order']['customer_name']
    refute payload['catalog']['needs_identification']

    assert submit(catalog, quantities: { variant.id => 4 })['ok']
    assert submit(catalog, quantities: { variant.id => 5 })['ok']
    assert_equal 1, catalog.catalog_orders.count
    assert_equal @client, catalog.catalog_orders.first.client
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `... bin/rails test test/controllers/public_catalogs_controller_test.rb`
Expected: ERROR `uninitialized constant PublicCatalogsController`.

- [ ] **Step 3: Payload e controller**

`app/services/b2b_catalogs/public_payload.rb`:
```ruby
# Dados da página pública (vão embutidos como JSON). Sem preço e sem o número exato do estoque:
# "max" é o limite do campo de quantidade.
module B2bCatalogs
  class PublicPayload
    def initialize(catalog, order)
      @catalog = catalog
      @order = order
    end

    def as_json(*)
      { catalog: catalog_json, order: order_json, styles: styles_json }
    end

    private

    def catalog_json
      { title: @catalog.title, notes: @catalog.notes.to_s, closed: @catalog.closed?,
        needs_identification: @catalog.kind_general?,
        refreshed_at: @catalog.stock_refreshed_at&.strftime('%d/%m às %H:%M') }
    end

    def order_json
      return nil unless @order

      { customer_name: @order.customer_name, customer_registration: B2bCatalogs::Cnpj.format(@order.customer_registration),
        converted: @order.converted?, persisted: @order.persisted?,
        quantities: @order.persisted? ? @order.items.to_h { |i| [i.b2b_catalog_variant_id.to_s, i.quantity] } : {} }
    end

    def styles_json
      @catalog.styles.map do |style, colors|
        { name: style, colors: colors.map { |color| color_json(color) } }
      end
    end

    def color_json(color)
      { id: color.id, name: color.color_name, images: Array(color.image_urls).map { |url| sized(url) },
        variants: color.variants.map do |v|
          { id: v.id, size: v.size, availability: v.availability, max: v.sold_out? ? 0 : [v.available, 0].max }
        end }
    end

    # Shopify CDN redimensiona pela query string.
    def sized(url)
      return url unless url.to_s.include?('cdn.shopify.com')

      "#{url}#{url.include?('?') ? '&' : '?'}width=900"
    end
  end
end
```

`app/controllers/public_catalogs_controller.rb`:
```ruby
# Página pública do catálogo B2B (único controller sem login do app). O lojista escolhe modelos,
# cores e tamanhos e envia uma encomenda; pode alterar até ela virar pedido.
class PublicCatalogsController < ApplicationController
  skip_before_action :authenticate_user!
  layout 'public_catalog'
  before_action :set_catalog

  def show
    @payload = B2bCatalogs::PublicPayload.new(@catalog, current_order).as_json
  end

  def submit
    return fail_with('Este catálogo foi encerrado e não recebe mais encomendas.') if @catalog.closed?

    order = order_for_submit
    return fail_with('Esta encomenda já está em andamento e não pode mais ser alterada. Fale com a Chase.') if order.persisted? && order.converted?

    quantities = submitted_quantities
    return fail_with('Escolha pelo menos uma peça.') if quantities.values.sum <= 0
    if (error = @catalog.quantity_error(quantities))
      return fail_with(error)
    end

    order.assign_attributes(status: :pending, submitted_at: Time.current)
    return fail_with(order.errors.full_messages.to_sentence) unless order.save

    order.replace_items!(quantities, edited_by: 'customer')
    remember(order)
    render json: { ok: true, order: B2bCatalogs::PublicPayload.new(@catalog, order).as_json[:order] }
  end

  def identify
    order = @catalog.catalog_orders.find_by(customer_registration: B2bCatalogs::Cnpj.digits(params[:customer_registration]).presence)
    remember(order) if order
    render json: { ok: true, order: order && B2bCatalogs::PublicPayload.new(@catalog, order).as_json[:order] }
  end

  private

  def set_catalog
    @catalog = B2bCatalog.includes(products: :variants).find_by(public_token: params[:token].to_s)
    return if @catalog

    request.format.json? ? head(:not_found) : render(:unavailable, status: :not_found)
  end

  def cookie_key = "catalog_order_#{@catalog.id}"

  def remember(order)
    cookies.signed[cookie_key] = { value: order.edit_token, expires: 1.year, httponly: true }
  end

  # Encomenda que a página deve mostrar: do cliente (catálogo por cliente) ou a do cookie (geral).
  def current_order
    if @catalog.kind_client?
      @catalog.catalog_orders.first || client_order_template
    else
      token = cookies.signed[cookie_key]
      token.present? ? @catalog.catalog_orders.find_by(edit_token: token) : nil
    end
  end

  def order_for_submit
    return @catalog.catalog_orders.first || client_order_template if @catalog.kind_client?

    registration = B2bCatalogs::Cnpj.digits(params[:customer_registration]).presence
    order = registration ? @catalog.catalog_orders.find_or_initialize_by(customer_registration: registration) : @catalog.catalog_orders.new
    order.customer_name = params[:customer_name].to_s.strip.presence || order.customer_name
    order
  end

  def client_order_template
    client = @catalog.client
    @catalog.catalog_orders.new(client:, customer_name: client.display_name,
                                customer_registration: client.registration.to_s.gsub(/\D/, '').presence)
  end

  def submitted_quantities
    raw = params[:quantities]
    raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
    (raw || {}).to_h.transform_keys(&:to_i).transform_values(&:to_i).reject { |_, q| q <= 0 }
  end

  def fail_with(message)
    render json: { ok: false, error: message }, status: :unprocessable_entity
  end
end
```

> `ApplicationController` tem `protect_from_forgery unless: -> { request.format.json? }`; as rotas `submit`/`identify` têm `defaults: { format: :json }`, então não exigem token CSRF (não há sessão de usuário nelas). A página ainda manda o token pelo `csrf_meta_tags`.

> No teste "quantities above available", `submitted_quantities` descarta `q <= 0`, então `{ @p.id => 0 }` vira `{}` e cai em "pelo menos uma peça".

- [ ] **Step 4: Layout e views**

`app/views/layouts/public_catalog.html.erb`:
```erb
<!DOCTYPE html>
<html lang="pt-BR">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <meta name="robots" content="noindex, nofollow">
  <title><%= content_for?(:title) ? yield(:title) : 'Catálogo Chase' %></title>
  <%= csrf_meta_tags %>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Archivo:wght@400;500;600;700;800;900&display=swap" rel="stylesheet">
  <%= stylesheet_link_tag 'public_catalog', media: 'all' %>
</head>
<body class="pc-body">
  <%= yield %>
</body>
</html>
```

`app/views/public_catalogs/unavailable.html.erb`:
```erb
<% content_for :title, 'Catálogo indisponível' %>
<main class="pc-closed pc-closed--full">
  <div class="pc-brand">CHASE</div>
  <h1>Catálogo indisponível</h1>
  <p>Este link não existe mais. Peça um link novo para a equipe da Chase.</p>
</main>
```

`app/views/public_catalogs/show.html.erb`:
```erb
<% content_for :title, "#{@catalog.title} · Chase" %>
<script type="application/json" id="catalogData"><%= raw json_escape(@payload.to_json) %></script>

<header class="pc-header">
  <div class="pc-brand">CHASE</div>
  <button type="button" class="pc-link" id="pcIdentifyOpen" hidden>Já fiz uma encomenda</button>
</header>

<section class="pc-hero">
  <p class="pc-hero__eyebrow">Catálogo atacado</p>
  <h1 class="pc-hero__title"><%= @catalog.title %></h1>
  <% if @catalog.notes.present? %><p class="pc-hero__notes"><%= @catalog.notes %></p><% end %>
  <p class="pc-hero__meta" id="pcRefreshed"></p>
</section>

<% if @catalog.closed? %>
  <section class="pc-closed"><h2>Este catálogo foi encerrado</h2><p>As encomendas não podem mais ser enviadas ou alteradas. Fale com a equipe da Chase.</p></section>
<% end %>

<div class="pc-banner" id="pcBanner" hidden></div>

<main class="pc-grid" id="pcGrid"></main>

<div class="pc-bar" id="pcBar">
  <button type="button" class="pc-bar__summary" id="pcSummaryOpen">
    <span class="pc-bar__count" id="pcCount">0</span><span id="pcCountLabel">peças selecionadas</span>
  </button>
  <button type="button" class="pc-btn pc-btn--light" id="pcSubmit" disabled>Enviar encomenda</button>
</div>

<div class="pc-overlay" id="pcOverlay" hidden></div>

<aside class="pc-drawer" id="pcProduct" aria-hidden="true">
  <button type="button" class="pc-drawer__close" data-close>&times;</button>
  <div class="pc-product">
    <div class="pc-gallery"><div class="pc-gallery__main" id="pcGalleryMain"></div><div class="pc-gallery__thumbs" id="pcGalleryThumbs"></div></div>
    <div class="pc-product__info">
      <h2 class="pc-product__style" id="pcProductStyle"></h2>
      <p class="pc-product__color" id="pcProductColor"></p>
      <div class="pc-swatches pc-swatches--large" id="pcProductSwatches"></div>
      <p class="pc-label">Tamanhos</p>
      <div class="pc-sizes" id="pcProductSizes"></div>
      <button type="button" class="pc-btn" data-close>Continuar escolhendo</button>
    </div>
  </div>
</aside>

<aside class="pc-drawer pc-drawer--summary" id="pcSummary" aria-hidden="true">
  <button type="button" class="pc-drawer__close" data-close>&times;</button>
  <h2 class="pc-drawer__title">Sua seleção</h2>
  <div id="pcSummaryList" class="pc-summary"></div>
  <button type="button" class="pc-btn" id="pcSummarySubmit">Enviar encomenda</button>
</aside>

<div class="pc-modal" id="pcIdentify" aria-hidden="true">
  <form class="pc-modal__box" id="pcIdentifyForm" novalidate>
    <button type="button" class="pc-drawer__close" data-close>&times;</button>
    <h2 class="pc-drawer__title" id="pcIdentifyTitle">Quem está encomendando?</h2>
    <p class="pc-muted" id="pcIdentifyText">Usamos o CNPJ para guardar sua encomenda. Você pode voltar e alterar até ela virar pedido.</p>
    <label class="pc-field" id="pcNameField"><span>Nome da loja</span><input type="text" id="pcName" autocomplete="organization"></label>
    <label class="pc-field"><span>CNPJ</span><input type="text" id="pcCnpj" inputmode="numeric" placeholder="00.000.000/0000-00"></label>
    <p class="pc-error" id="pcIdentifyError" hidden></p>
    <button type="submit" class="pc-btn" id="pcIdentifySubmit">Enviar encomenda</button>
  </form>
</div>

<div class="pc-success" id="pcSuccess" hidden>
  <div class="pc-success__box">
    <svg class="pc-check" viewBox="0 0 52 52"><circle cx="26" cy="26" r="24"/><path d="M14 27l8 8 16-17"/></svg>
    <h2>Encomenda enviada!</h2>
    <p id="pcSuccessText">Recebemos sua seleção. Você pode voltar a este link e alterar até ela virar pedido.</p>
    <button type="button" class="pc-btn" id="pcSuccessClose">Voltar ao catálogo</button>
  </div>
</div>

<div class="pc-toast" id="pcToast" hidden></div>

<script>
(function () {
  var data = JSON.parse(document.getElementById('catalogData').textContent);
  var catalog = data.catalog;
  var order = data.order;
  var quantities = {};
  var variantsById = {};
  var colorsById = {};
  var locked = catalog.closed || (order && order.converted);
  var submitUrl = '<%= public_catalog_submit_path(@catalog.public_token) %>';
  var identifyUrl = '<%= public_catalog_identify_path(@catalog.public_token) %>';
  var csrf = document.querySelector('meta[name="csrf-token"]');

  function $(id) { return document.getElementById(id); }
  function esc(s) { var d = document.createElement('div'); d.textContent = s == null ? '' : s; return d.innerHTML; }
  var LEVEL = { available: 'Disponível', low: 'Últimas unidades', sold_out: 'Esgotado' };

  data.styles.forEach(function (style) {
    style.colors.forEach(function (color) {
      color.style = style.name;
      colorsById[color.id] = color;
      color.variants.forEach(function (v) { v.color = color; variantsById[v.id] = v; });
    });
  });
  if (order && order.quantities) Object.keys(order.quantities).forEach(function (id) { if (variantsById[id]) quantities[id] = order.quantities[id]; });

  if (catalog.refreshed_at) $('pcRefreshed').textContent = 'Disponibilidade atualizada em ' + catalog.refreshed_at;
  if (catalog.needs_identification && !locked) $('pcIdentifyOpen').hidden = false;
  if (order && order.converted) showBanner('Sua encomenda foi recebida e está em andamento. Para mudar algo, fale com a Chase.');
  else if (order && order.persisted) showBanner('Olá, ' + order.customer_name + '! Esta é a sua encomenda salva. Altere o que quiser e envie de novo.');

  function showBanner(text) { var b = $('pcBanner'); b.textContent = text; b.hidden = false; }

  function toast(text, error) {
    var t = $('pcToast');
    t.textContent = text; t.className = 'pc-toast' + (error ? ' pc-toast--error' : ''); t.hidden = false;
    clearTimeout(toast.timer); toast.timer = setTimeout(function () { t.hidden = true; }, 4200);
  }

  function totalPieces() { return Object.keys(quantities).reduce(function (sum, id) { return sum + (quantities[id] || 0); }, 0); }
  function colorPieces(color) { return color.variants.reduce(function (s, v) { return s + (quantities[v.id] || 0); }, 0); }

  function imageHtml(url, alt, cls) {
    return url ? '<img src="' + esc(url) + '" alt="' + esc(alt) + '" loading="lazy" class="' + (cls || '') + '">' : '<div class="pc-placeholder ' + (cls || '') + '">CHASE</div>';
  }

  // ---- Grade de modelos (um card por modelo, bolinhas trocam a cor) ----
  function renderGrid() {
    var grid = $('pcGrid');
    grid.innerHTML = '';
    data.styles.forEach(function (style, index) {
      var card = document.createElement('article');
      card.className = 'pc-card';
      card.style.animationDelay = Math.min(index, 16) * 60 + 'ms';
      card.dataset.color = style.colors[0].id;
      grid.appendChild(card);
      paintCard(card, style);
    });
  }

  function paintCard(card, style) {
    var color = colorsById[card.dataset.color];
    var allSoldOut = color.variants.every(function (v) { return v.availability === 'sold_out'; });
    var picked = colorPieces(color);
    card.innerHTML =
      '<button type="button" class="pc-card__media" data-open="' + color.id + '">' +
        imageHtml(color.images[0], style.name, 'pc-card__img') +
        (color.images[1] ? imageHtml(color.images[1], style.name, 'pc-card__img pc-card__img--alt') : '') +
        (allSoldOut ? '<span class="pc-tag pc-tag--dark">Esgotado</span>' : '') +
        (picked ? '<span class="pc-tag pc-tag--picked">' + picked + ' peça' + (picked > 1 ? 's' : '') + '</span>' : '') +
      '</button>' +
      '<div class="pc-card__body">' +
        '<h3 class="pc-card__style">' + esc(style.name) + '</h3>' +
        '<p class="pc-card__color">' + esc(color.name) + ' · ' + style.colors.length + ' cor' + (style.colors.length > 1 ? 'es' : '') + '</p>' +
        '<div class="pc-swatches">' + style.colors.map(function (c) {
          return '<button type="button" class="pc-swatch' + (c.id == color.id ? ' pc-swatch--active' : '') + '" data-swatch="' + c.id + '" title="' + esc(c.name) + '">' +
            (c.images[0] ? '<img src="' + esc(c.images[0]) + '" alt="">' : '<span>' + esc(c.name.slice(0, 2)) + '</span>') + '</button>';
        }).join('') + '</div>' +
        '<div class="pc-card__sizes">' + color.variants.map(function (v) {
          return '<span class="pc-mini pc-mini--' + v.availability + '">' + esc(v.size) + '</span>';
        }).join('') + '</div>' +
      '</div>';
    card.querySelectorAll('[data-swatch]').forEach(function (btn) {
      btn.addEventListener('click', function () {
        card.dataset.color = btn.dataset.swatch;
        card.classList.remove('pc-card--swap'); void card.offsetWidth; card.classList.add('pc-card--swap');
        paintCard(card, style);
      });
    });
    card.querySelector('[data-open]').addEventListener('click', function () { openProduct(color.id); });
  }

  // ---- Produto (galeria + tamanhos) ----
  var openColorId = null;
  function openProduct(colorId) {
    openColorId = colorId;
    var color = colorsById[colorId];
    var style = data.styles.find(function (s) { return s.name === color.style; });
    $('pcProductStyle').textContent = color.style;
    $('pcProductColor').textContent = color.name;
    var main = $('pcGalleryMain');
    main.innerHTML = imageHtml(color.images[0], color.style, 'pc-gallery__img');
    $('pcGalleryThumbs').innerHTML = color.images.map(function (url, i) {
      return '<button type="button" class="pc-thumb' + (i === 0 ? ' pc-thumb--active' : '') + '" data-img="' + esc(url) + '"><img src="' + esc(url) + '" alt=""></button>';
    }).join('');
    $('pcGalleryThumbs').querySelectorAll('[data-img]').forEach(function (btn) {
      btn.addEventListener('click', function () {
        main.innerHTML = imageHtml(btn.dataset.img, color.style, 'pc-gallery__img pc-fade');
        $('pcGalleryThumbs').querySelectorAll('.pc-thumb').forEach(function (b) { b.classList.toggle('pc-thumb--active', b === btn); });
      });
    });
    $('pcProductSwatches').innerHTML = style.colors.map(function (c) {
      return '<button type="button" class="pc-swatch' + (c.id == color.id ? ' pc-swatch--active' : '') + '" data-color="' + c.id + '" title="' + esc(c.name) + '">' +
        (c.images[0] ? '<img src="' + esc(c.images[0]) + '" alt="">' : '<span>' + esc(c.name.slice(0, 2)) + '</span>') + '</button>';
    }).join('');
    $('pcProductSwatches').querySelectorAll('[data-color]').forEach(function (btn) {
      btn.addEventListener('click', function () { openProduct(btn.dataset.color); });
    });
    renderSizes(color);
    openDrawer('pcProduct');
  }

  function renderSizes(color) {
    $('pcProductSizes').innerHTML = color.variants.map(function (v) {
      var q = quantities[v.id] || 0;
      var disabled = locked || v.availability === 'sold_out';
      return '<div class="pc-size pc-size--' + v.availability + (q ? ' pc-size--picked' : '') + '">' +
        '<div class="pc-size__head"><strong>' + esc(v.size) + '</strong><small>' + LEVEL[v.availability] + '</small></div>' +
        '<div class="pc-stepper">' +
          '<button type="button" data-step="-1" data-id="' + v.id + '"' + (disabled || q <= 0 ? ' disabled' : '') + '>&minus;</button>' +
          '<input type="number" min="0" value="' + q + '" data-id="' + v.id + '"' + (disabled ? ' disabled' : '') + '>' +
          '<button type="button" data-step="1" data-id="' + v.id + '"' + (disabled || q >= v.max ? ' disabled' : '') + '>+</button>' +
        '</div></div>';
    }).join('');
    $('pcProductSizes').querySelectorAll('[data-step]').forEach(function (btn) {
      btn.addEventListener('click', function () { setQuantity(btn.dataset.id, (quantities[btn.dataset.id] || 0) + parseInt(btn.dataset.step, 10)); });
    });
    $('pcProductSizes').querySelectorAll('input[data-id]').forEach(function (input) {
      input.addEventListener('change', function () { setQuantity(input.dataset.id, parseInt(input.value, 10) || 0); });
    });
  }

  function setQuantity(id, value) {
    var v = variantsById[id];
    if (!v || locked) return;
    var clamped = Math.max(0, Math.min(value, v.max));
    if (value > v.max) toast(v.color.style + ' ' + v.color.name + ' ' + v.size + ': esta é a quantidade máxima disponível.');
    if (clamped) quantities[id] = clamped; else delete quantities[id];
    renderSizes(v.color);
    updateBar(true);
    renderGrid();
  }

  // ---- Barra fixa e resumo ----
  function updateBar(bump) {
    var total = totalPieces();
    $('pcCount').textContent = total;
    $('pcCountLabel').textContent = total === 1 ? 'peça selecionada' : 'peças selecionadas';
    $('pcSubmit').disabled = locked || total === 0;
    $('pcSummarySubmit').disabled = locked || total === 0;
    if (bump) { var c = $('pcCount'); c.classList.remove('pc-bump'); void c.offsetWidth; c.classList.add('pc-bump'); }
  }

  function renderSummary() {
    var rows = [];
    data.styles.forEach(function (style) {
      style.colors.forEach(function (color) {
        color.variants.forEach(function (v) {
          if (quantities[v.id]) rows.push({ v: v, color: color, style: style });
        });
      });
    });
    $('pcSummaryList').innerHTML = rows.length ? rows.map(function (r) {
      return '<div class="pc-summary__row">' + imageHtml(r.color.images[0], r.style.name, 'pc-summary__img') +
        '<div><strong>' + esc(r.style.name) + '</strong><span>' + esc(r.color.name) + ' · ' + esc(r.v.size) + '</span></div>' +
        '<b>&times; ' + quantities[r.v.id] + '</b>' +
        (locked ? '' : '<button type="button" class="pc-link" data-edit="' + r.color.id + '">Alterar</button>') + '</div>';
    }).join('') : '<p class="pc-muted">Nenhuma peça escolhida ainda.</p>';
    $('pcSummaryList').querySelectorAll('[data-edit]').forEach(function (btn) {
      btn.addEventListener('click', function () { closeAll(); openProduct(btn.dataset.edit); });
    });
  }

  // ---- Gavetas e modais ----
  function openDrawer(id) {
    closeAll(true);
    $('pcOverlay').hidden = false;
    $(id).classList.add('pc-open');
    $(id).setAttribute('aria-hidden', 'false');
    document.body.classList.add('pc-lock');
  }
  function closeAll(keepOverlay) {
    ['pcProduct', 'pcSummary', 'pcIdentify'].forEach(function (id) { $(id).classList.remove('pc-open'); $(id).setAttribute('aria-hidden', 'true'); });
    if (!keepOverlay) { $('pcOverlay').hidden = true; document.body.classList.remove('pc-lock'); }
  }
  document.querySelectorAll('[data-close]').forEach(function (b) { b.addEventListener('click', function () { closeAll(); }); });
  $('pcOverlay').addEventListener('click', function () { closeAll(); });
  document.addEventListener('keydown', function (e) { if (e.key === 'Escape') closeAll(); });

  $('pcSummaryOpen').addEventListener('click', function () { renderSummary(); openDrawer('pcSummary'); });

  // ---- Identificação e envio ----
  var identifyMode = 'submit';
  function maskCnpj(value) {
    var d = value.replace(/\D/g, '').slice(0, 14);
    return d.replace(/^(\d{2})(\d)/, '$1.$2').replace(/^(\d{2})\.(\d{3})(\d)/, '$1.$2.$3').replace(/\.(\d{3})(\d)/, '.$1/$2').replace(/(\d{4})(\d)/, '$1-$2');
  }
  $('pcCnpj').addEventListener('input', function (e) { e.target.value = maskCnpj(e.target.value); });

  function askIdentity(mode) {
    identifyMode = mode;
    $('pcIdentifyTitle').textContent = mode === 'lookup' ? 'Continuar minha encomenda' : 'Quem está encomendando?';
    $('pcIdentifyText').textContent = mode === 'lookup' ? 'Informe o CNPJ usado na encomenda.' : 'Usamos o CNPJ para guardar sua encomenda. Você pode voltar e alterar até ela virar pedido.';
    $('pcNameField').hidden = mode === 'lookup';
    $('pcIdentifySubmit').textContent = mode === 'lookup' ? 'Continuar' : 'Enviar encomenda';
    $('pcIdentifyError').hidden = true;
    if (order) { $('pcName').value = order.customer_name || ''; $('pcCnpj').value = order.customer_registration || ''; }
    openDrawer('pcIdentify');
  }
  $('pcIdentifyOpen').addEventListener('click', function () { askIdentity('lookup'); });

  function startSubmit() {
    if (locked || totalPieces() === 0) return;
    if (catalog.needs_identification && !(order && order.persisted)) return askIdentity('submit');
    if (catalog.needs_identification) return askIdentity('submit');
    send({});
  }
  $('pcSubmit').addEventListener('click', startSubmit);
  $('pcSummarySubmit').addEventListener('click', startSubmit);

  $('pcIdentifyForm').addEventListener('submit', function (e) {
    e.preventDefault();
    var cnpj = $('pcCnpj').value;
    if (identifyMode === 'lookup') {
      post(identifyUrl, { customer_registration: cnpj }).then(function (res) {
        if (!res.order) { showIdentifyError('Não encontramos encomenda com este CNPJ neste catálogo.'); return; }
        order = res.order; quantities = {};
        Object.keys(order.quantities).forEach(function (id) { if (variantsById[id]) quantities[id] = order.quantities[id]; });
        locked = catalog.closed || order.converted;
        closeAll(); renderGrid(); updateBar(true);
        showBanner(order.converted ? 'Sua encomenda foi recebida e está em andamento.' : 'Encomenda de ' + order.customer_name + ' carregada. Altere o que quiser e envie de novo.');
      });
      return;
    }
    var name = $('pcName').value.trim();
    if (!name) { showIdentifyError('Informe o nome da loja.'); return; }
    if (cnpj.replace(/\D/g, '').length !== 14) { showIdentifyError('Informe um CNPJ com 14 dígitos.'); return; }
    send({ customer_name: name, customer_registration: cnpj });
  });

  function showIdentifyError(text) { var el = $('pcIdentifyError'); el.textContent = text; el.hidden = false; }

  function post(url, body) {
    return fetch(url, {
      method: 'POST', credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json', 'Accept': 'application/json', 'X-CSRF-Token': csrf ? csrf.content : '' },
      body: JSON.stringify(body)
    }).then(function (r) { return r.json(); });
  }

  function send(identity) {
    var body = Object.assign({ quantities: quantities }, identity);
    $('pcSubmit').classList.add('pc-btn--loading');
    post(submitUrl, body).then(function (res) {
      $('pcSubmit').classList.remove('pc-btn--loading');
      if (!res.ok) {
        if ($('pcIdentify').classList.contains('pc-open')) showIdentifyError(res.error); else toast(res.error, true);
        return;
      }
      order = res.order;
      closeAll();
      $('pcSuccessText').textContent = 'Recebemos ' + totalPieces() + ' peça(s), ' + order.customer_name + '. Você pode voltar a este link e alterar até a encomenda virar pedido.';
      $('pcSuccess').hidden = false;
      $('pcSuccess').classList.remove('pc-success--in'); void $('pcSuccess').offsetWidth; $('pcSuccess').classList.add('pc-success--in');
      showBanner('Encomenda salva. Altere o que quiser e envie de novo.');
    }).catch(function () {
      $('pcSubmit').classList.remove('pc-btn--loading');
      toast('Não conseguimos enviar agora. Verifique a internet e tente de novo.', true);
    });
  }
  $('pcSuccessClose').addEventListener('click', function () { $('pcSuccess').hidden = true; });

  renderGrid();
  updateBar(false);
})();
</script>
```

- [ ] **Step 5: Estilo da página pública (linha Gymshark)**

`app/assets/stylesheets/public_catalog.scss` (pré-compilado pelo `*.scss` em `config/initializers/assets.rb`):
```scss
$ink: #111111;
$paper: #ffffff;
$mist: #f4f4f4;
$line: #e6e6e6;
$muted: #767676;
$accent: #111111;
$low: #e8590c;
$ok: #2b8a3e;
$danger: #c92a2a;
$ease: cubic-bezier(0.22, 1, 0.36, 1);

@keyframes pc-rise { from { opacity: 0; transform: translateY(18px); } to { opacity: 1; transform: none; } }
@keyframes pc-fade { from { opacity: 0; } to { opacity: 1; } }
@keyframes pc-bump { 0% { transform: scale(1); } 40% { transform: scale(1.35); } 100% { transform: scale(1); } }
@keyframes pc-draw { to { stroke-dashoffset: 0; } }
@keyframes pc-spin { to { transform: rotate(360deg); } }
@keyframes pc-marquee { from { background-position: 0 0; } to { background-position: 200% 0; } }

*, *::before, *::after { box-sizing: border-box; }
html, body { margin: 0; padding: 0; }
.pc-body {
  background: $paper; color: $ink;
  font-family: 'Archivo', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
  -webkit-font-smoothing: antialiased;
  padding-bottom: 96px;
  &.pc-lock { overflow: hidden; }
}
button { font-family: inherit; cursor: pointer; }
img { display: block; max-width: 100%; }

.pc-header {
  position: sticky; top: 0; z-index: 20;
  display: flex; justify-content: space-between; align-items: center;
  padding: 14px 16px; background: rgba($paper, 0.92); backdrop-filter: blur(10px);
  border-bottom: 1px solid $line;
}
.pc-brand { font-weight: 900; font-size: 22px; letter-spacing: 0.32em; }
.pc-link { background: none; border: 0; padding: 0; color: $ink; font-weight: 700; font-size: 13px; text-decoration: underline; text-underline-offset: 3px; }

.pc-hero {
  padding: 48px 16px 28px; max-width: 1400px; margin: 0 auto;
  animation: pc-rise 0.7s $ease both;
  &__eyebrow { margin: 0 0 10px; font-size: 12px; font-weight: 700; letter-spacing: 0.24em; text-transform: uppercase; color: $muted; }
  &__title { margin: 0; font-size: clamp(36px, 9vw, 88px); line-height: 0.92; font-weight: 900; text-transform: uppercase; letter-spacing: -0.02em; }
  &__notes { margin: 18px 0 0; max-width: 640px; font-size: 16px; line-height: 1.5; }
  &__meta { margin: 14px 0 0; font-size: 12px; color: $muted; letter-spacing: 0.04em; }
}

.pc-banner {
  max-width: 1400px; margin: 0 auto 18px; padding: 12px 16px;
  background: $ink; color: $paper; font-weight: 600; font-size: 14px;
  animation: pc-rise 0.5s $ease both;
}
@media (min-width: 720px) { .pc-banner { margin: 0 16px 18px; border-radius: 2px; } }

.pc-closed {
  max-width: 1400px; margin: 0 auto 18px; padding: 28px 16px; text-align: center;
  background: $mist;
  h1, h2 { margin: 0 0 8px; font-weight: 900; text-transform: uppercase; }
  p { margin: 0; color: $muted; }
  &--full { min-height: 100vh; display: flex; flex-direction: column; justify-content: center; align-items: center; gap: 12px; background: $paper; }
}

.pc-grid {
  display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 28px 10px;
  max-width: 1400px; margin: 0 auto; padding: 0 10px;
}
@media (min-width: 900px) { .pc-grid { grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 40px 16px; padding: 0 16px; } }
@media (min-width: 1200px) { .pc-grid { grid-template-columns: repeat(4, minmax(0, 1fr)); } }

.pc-card {
  animation: pc-rise 0.6s $ease both;
  &--swap .pc-card__media { animation: pc-fade 0.45s ease; }

  &__media {
    position: relative; display: block; width: 100%; padding: 0; border: 0;
    aspect-ratio: 4 / 5; overflow: hidden; background: $mist;
    &:hover .pc-card__img--alt { opacity: 1; }
    &:hover .pc-card__img { transform: scale(1.03); }
  }
  &__img { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; transition: transform 0.8s $ease, opacity 0.5s ease; }
  &__img--alt { opacity: 0; }
  &__body { padding-top: 12px; }
  &__style { margin: 0; font-size: 14px; font-weight: 800; text-transform: uppercase; letter-spacing: 0.02em; line-height: 1.2; }
  &__color { margin: 4px 0 10px; font-size: 13px; color: $muted; }
  &__sizes { display: flex; flex-wrap: wrap; gap: 4px; margin-top: 10px; }
}

.pc-tag {
  position: absolute; left: 10px; top: 10px; padding: 5px 9px;
  font-size: 11px; font-weight: 800; letter-spacing: 0.08em; text-transform: uppercase;
  &--dark { background: $ink; color: $paper; }
  &--picked { left: auto; right: 10px; background: $paper; color: $ink; box-shadow: 0 2px 10px rgba(0, 0, 0, 0.12); animation: pc-bump 0.4s ease; }
}

.pc-placeholder { display: flex; align-items: center; justify-content: center; background: $mist; color: #c7c7c7; font-weight: 900; letter-spacing: 0.3em; width: 100%; height: 100%; }

.pc-swatches {
  display: flex; flex-wrap: wrap; gap: 6px;
  &--large .pc-swatch { width: 44px; height: 44px; }
}
.pc-swatch {
  width: 28px; height: 28px; padding: 2px; border: 1px solid $line; border-radius: 50%; background: $paper; overflow: hidden;
  transition: transform 0.2s ease, border-color 0.2s ease;
  img { width: 100%; height: 100%; border-radius: 50%; object-fit: cover; }
  span { display: flex; width: 100%; height: 100%; align-items: center; justify-content: center; font-size: 10px; font-weight: 800; text-transform: uppercase; border-radius: 50%; background: $mist; }
  &:hover { transform: scale(1.1); }
  &--active { border: 2px solid $ink; }
}

.pc-mini {
  min-width: 26px; padding: 2px 5px; text-align: center; font-size: 11px; font-weight: 700; border: 1px solid $line;
  &--low { border-color: $low; color: $low; }
  &--sold_out { color: #bdbdbd; text-decoration: line-through; }
}

.pc-bar {
  position: fixed; left: 0; right: 0; bottom: 0; z-index: 30;
  display: flex; align-items: center; justify-content: space-between; gap: 12px;
  padding: 12px 16px calc(12px + env(safe-area-inset-bottom));
  background: $ink; color: $paper;
  box-shadow: 0 -8px 30px rgba(0, 0, 0, 0.18);
  &__summary { display: flex; align-items: center; gap: 10px; background: none; border: 0; color: $paper; font-size: 14px; font-weight: 600; }
  &__count { min-width: 34px; height: 34px; display: inline-flex; align-items: center; justify-content: center; padding: 0 8px; border-radius: 17px; background: $paper; color: $ink; font-weight: 900; }
}
.pc-bump { animation: pc-bump 0.45s ease; }

.pc-btn {
  display: inline-flex; align-items: center; justify-content: center; gap: 8px;
  width: 100%; padding: 16px 22px; border: 0; background: $ink; color: $paper;
  font-size: 14px; font-weight: 800; letter-spacing: 0.12em; text-transform: uppercase;
  transition: transform 0.15s ease, opacity 0.2s ease;
  &:active { transform: scale(0.98); }
  &:disabled { opacity: 0.35; cursor: not-allowed; }
  &--light { width: auto; background: $paper; color: $ink; }
  &--loading { pointer-events: none; opacity: 0.7; &::after { content: ''; width: 14px; height: 14px; border: 2px solid currentColor; border-right-color: transparent; border-radius: 50%; animation: pc-spin 0.7s linear infinite; } }
}

.pc-overlay { position: fixed; inset: 0; z-index: 40; background: rgba(0, 0, 0, 0.45); animation: pc-fade 0.25s ease; }

.pc-drawer, .pc-modal {
  position: fixed; z-index: 50; background: $paper; overflow-y: auto;
  transition: transform 0.45s $ease, opacity 0.3s ease;
}
.pc-drawer {
  left: 0; right: 0; bottom: 0; max-height: 92vh; transform: translateY(100%);
  padding: 22px 18px calc(22px + env(safe-area-inset-bottom));
  border-radius: 14px 14px 0 0;
  &.pc-open { transform: none; }
  &__close { position: absolute; top: 10px; right: 12px; z-index: 2; width: 38px; height: 38px; border: 0; background: $paper; font-size: 28px; line-height: 1; }
  &__title { margin: 0 0 16px; font-size: 22px; font-weight: 900; text-transform: uppercase; }
}
@media (min-width: 900px) {
  .pc-drawer { left: auto; top: 0; bottom: 0; width: min(560px, 100vw); max-height: none; transform: translateX(100%); border-radius: 0; padding: 28px; }
  .pc-drawer--summary { width: 440px; }
}

.pc-modal {
  inset: 0; display: flex; align-items: center; justify-content: center; padding: 16px;
  background: transparent; opacity: 0; pointer-events: none;
  &.pc-open { opacity: 1; pointer-events: auto; }
  &__box { position: relative; width: 100%; max-width: 440px; padding: 30px 24px 24px; background: $paper; box-shadow: 0 30px 80px rgba(0, 0, 0, 0.25); animation: pc-rise 0.4s $ease both; }
}

.pc-product { display: flex; flex-direction: column; gap: 18px; }
.pc-product__style { margin: 0; font-size: 24px; font-weight: 900; text-transform: uppercase; line-height: 1.05; }
.pc-product__color { margin: 6px 0 14px; color: $muted; }
.pc-label { margin: 22px 0 10px; font-size: 12px; font-weight: 800; letter-spacing: 0.16em; text-transform: uppercase; }

.pc-gallery {
  &__main { aspect-ratio: 4 / 5; background: $mist; overflow: hidden; }
  &__img { width: 100%; height: 100%; object-fit: cover; }
  &__thumbs { display: flex; gap: 6px; margin-top: 8px; overflow-x: auto; }
}
.pc-fade { animation: pc-fade 0.4s ease; }
.pc-thumb { flex: 0 0 58px; height: 72px; padding: 0; border: 2px solid transparent; background: $mist; img { width: 100%; height: 100%; object-fit: cover; } &--active { border-color: $ink; } }

.pc-sizes { display: grid; grid-template-columns: repeat(auto-fill, minmax(140px, 1fr)); gap: 8px; margin-bottom: 20px; }
.pc-size {
  display: flex; flex-direction: column; gap: 8px; padding: 10px; border: 1px solid $line;
  transition: border-color 0.2s ease, box-shadow 0.2s ease;
  &__head { display: flex; justify-content: space-between; align-items: baseline; strong { font-size: 16px; } small { font-size: 11px; color: $ok; font-weight: 700; } }
  &--low .pc-size__head small { color: $low; }
  &--sold_out { background: $mist; .pc-size__head strong { text-decoration: line-through; color: #a3a3a3; } .pc-size__head small { color: $muted; } }
  &--picked { border-color: $ink; box-shadow: inset 0 0 0 1px $ink; }
}
.pc-stepper {
  display: grid; grid-template-columns: 36px 1fr 36px; border: 1px solid $line;
  button { height: 36px; border: 0; background: $paper; font-size: 18px; font-weight: 700; &:disabled { color: #cfcfcf; cursor: not-allowed; } }
  input { width: 100%; border: 0; border-left: 1px solid $line; border-right: 1px solid $line; text-align: center; font: inherit; font-weight: 800; -moz-appearance: textfield; &::-webkit-inner-spin-button { display: none; } &:disabled { background: $mist; } }
}

.pc-summary { display: flex; flex-direction: column; gap: 10px; margin-bottom: 18px; }
.pc-summary__row {
  display: grid; grid-template-columns: 56px 1fr auto auto; gap: 12px; align-items: center; padding-bottom: 10px; border-bottom: 1px solid $line;
  animation: pc-rise 0.35s $ease both;
  strong { display: block; font-size: 13px; text-transform: uppercase; }
  span { font-size: 13px; color: $muted; }
  b { font-size: 15px; }
}
.pc-summary__img { width: 56px; height: 70px; object-fit: cover; background: $mist; }

.pc-field {
  display: block; margin-bottom: 14px;
  span { display: block; margin-bottom: 6px; font-size: 12px; font-weight: 800; letter-spacing: 0.12em; text-transform: uppercase; }
  input { width: 100%; padding: 14px; border: 1px solid #cfcfcf; font: inherit; font-size: 16px; &:focus { outline: none; border-color: $ink; box-shadow: 0 0 0 1px $ink; } }
}
.pc-muted { color: $muted; font-size: 14px; line-height: 1.5; }
.pc-error { margin: 0 0 12px; padding: 10px 12px; background: rgba($danger, 0.08); color: $danger; font-size: 14px; font-weight: 600; }

.pc-success {
  position: fixed; inset: 0; z-index: 60; display: flex; align-items: center; justify-content: center; padding: 16px;
  background: rgba($paper, 0.96);
  &--in .pc-success__box { animation: pc-rise 0.6s $ease both; }
  &__box { max-width: 420px; text-align: center; h2 { margin: 18px 0 8px; font-size: 30px; font-weight: 900; text-transform: uppercase; } p { margin: 0 0 22px; color: $muted; line-height: 1.5; } }
}
.pc-check {
  width: 84px; height: 84px; margin: 0 auto; fill: none; stroke: $ink; stroke-width: 3;
  circle { stroke-dasharray: 160; stroke-dashoffset: 160; animation: pc-draw 0.7s $ease forwards; }
  path { stroke-dasharray: 40; stroke-dashoffset: 40; animation: pc-draw 0.45s $ease 0.55s forwards; }
}

.pc-toast {
  position: fixed; left: 50%; bottom: 92px; z-index: 70; transform: translateX(-50%);
  max-width: calc(100vw - 32px); padding: 12px 18px; background: $ink; color: $paper; font-size: 14px; font-weight: 600;
  animation: pc-rise 0.35s $ease both;
  &--error { background: $danger; }
}

@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after { animation-duration: 0.01ms !important; transition-duration: 0.01ms !important; }
}
```

- [ ] **Step 6: Run tests**

Run: `... bin/rails test test/controllers/public_catalogs_controller_test.rb`
Expected: PASS.

- [ ] **Step 7: JS e visual**

Renderizar a página num teste de dump (padrão já usado: escrever o HTML em arquivo), conferir o JS com `node --check`, simular no jsdom (do scratchpad) os fluxos: escolher tamanho, limite no `max`, esgotado desabilitado, troca de cor no card, resumo, identificação com CNPJ (fetch mockado), sucesso. Renderizar com `qlmanage -t` (CSS de `public_catalog.scss` compilado e embutido) em largura de celular (420) e desktop (1400) e revisar a beleza: hero, grade, cards, swatches, drawer.

---

### Task 6: PDF do catálogo

**Files:**
- Modify: `Gemfile` (`gem 'rqrcode', '~> 2.2'`), `Gemfile.lock` (bundle install)
- Create: `app/services/b2b_catalog_pdf.rb`
- Test: `test/services/b2b_catalog_pdf_test.rb`, e no `test/controllers/b2b_catalogs_controller_test.rb`

**Interfaces:**
- Consumes: models (Task 1), action `pdf` (Task 3).
- Produces: `B2bCatalogPdf.new(catalog, public_url:)` com `#render -> String` e `#filename -> String`.

- [ ] **Step 1: Write the failing tests**

`test/services/b2b_catalog_pdf_test.rb`:
```ruby
require 'test_helper'
require 'webmock/minitest'

class B2bCatalogPdfTest < ActiveSupport::TestCase
  def setup
    user = User.create!(name: 'PDF', email: 'pdf_catalog@example.com', password: 'password123')
    Product.create!(sku: 'A-P', shopify_product_name: 'Top A Black', option1: 'P')
    Product.create!(sku: 'A-M', shopify_product_name: 'Top A Black', option1: 'M')
    @catalog = B2bCatalog.create!(title: 'Coleção Verão', notes: 'Até sexta', user: user,
                                  products_attributes: [{ style_name: 'Top Aurora', color_name: 'Black', skus: %w[A-P A-M] }])
    @catalog.products.first.update!(image_urls: ['https://cdn.example.com/a.png'])
    @catalog.variants.first.update!(available: 3, availability: :low)
  end

  test 'renders a PDF with the styles, colors and sizes, without prices' do
    png = File.binread(Rails.root.join('test/fixtures/files/tiny.png'))
    stub_request(:get, /cdn\.example\.com/).to_return(status: 200, body: png, headers: { 'Content-Type' => 'image/png' })

    pdf = B2bCatalogPdf.new(@catalog, public_url: 'https://honey.example.com/catalogo/abc')
    body = pdf.render

    assert body.start_with?('%PDF')
    assert_includes body, 'TOP AURORA'
    assert_includes body, 'Black'
    refute_includes body, 'R$'
    assert_equal 'catalogo-colecao-verao.pdf', pdf.filename
  end

  test 'a broken image becomes a placeholder instead of failing' do
    stub_request(:get, /cdn\.example\.com/).to_return(status: 500)

    assert B2bCatalogPdf.new(@catalog, public_url: 'https://x/catalogo/abc').render.start_with?('%PDF')
  end
end
```

Adicionar em `test/controllers/b2b_catalogs_controller_test.rb`:
```ruby
  test 'pdf downloads the catalog' do
    catalog = create_catalog
    get pdf_b2b_catalog_path(catalog)

    assert_equal 'application/pdf', response.media_type
    assert_match(/catalogo-colecao-verao\.pdf/, response.headers['Content-Disposition'])
  end
```

Criar `test/fixtures/files/tiny.png` (PNG 4×4 válido, gerado com `ruby -e "require 'chunky_png'..."` se disponível, senão com Prawn não — usar Python: `python3 -c "import zlib,struct;..."` para gerar um PNG RGB 4×4).

- [ ] **Step 2: Run to verify they fail**

Run: `... bin/rails test test/services/b2b_catalog_pdf_test.rb`
Expected: ERROR `uninitialized constant B2bCatalogPdf`.

- [ ] **Step 3: Gem**

Acrescentar `gem 'rqrcode', '~> 2.2'` ao `Gemfile` (perto de `prawn`) e rodar `bundle install`.

- [ ] **Step 4: Implement**

`app/services/b2b_catalog_pdf.rb`:
```ruby
require 'prawn'
require 'rqrcode'

Prawn::Fonts::AFM.hide_m17n_warning = true

# PDF do catálogo para mandar ao lojista: capa, modelos com as cores (foto, nome, tamanhos disponíveis
# na hora da geração) e, no fim, link + QR code da página onde ele faz a encomenda. Sem preço.
class B2bCatalogPdf
  INK = '111111'.freeze
  MUTED = '767676'.freeze
  MIST = 'F4F4F4'.freeze
  LOW = 'E8590C'.freeze
  IMAGE_TIMEOUT = 8
  COLUMNS = 3

  def initialize(catalog, public_url:)
    @catalog = catalog
    @public_url = public_url
    @images = {}
  end

  def filename
    "catalogo-#{@catalog.title.parameterize}.pdf"
  end

  def render
    pdf = Prawn::Document.new(page_size: 'A4', margin: [36, 36, 42, 36], info: { Title: @catalog.title })
    cover(pdf)
    @catalog.styles.each { |style, colors| style_section(pdf, style, colors) }
    closing(pdf)
    footer(pdf)
    pdf.render
  end

  private

  def cover(pdf)
    pdf.fill_color INK
    pdf.fill_rectangle [-36, pdf.bounds.top + 36], pdf.bounds.width + 72, 300
    pdf.fill_color 'FFFFFF'
    pdf.text_box 'CHASE', at: [0, pdf.bounds.top - 10], size: 22, style: :bold, character_spacing: 6
    pdf.text_box 'CATÁLOGO ATACADO', at: [0, pdf.bounds.top - 120], size: 10, style: :bold, character_spacing: 3
    pdf.text_box @catalog.title.upcase, at: [0, pdf.bounds.top - 140], width: pdf.bounds.width, size: 38, style: :bold, leading: -4
    pdf.fill_color INK
    pdf.move_down 290
    if @catalog.notes.present?
      pdf.text @catalog.notes, size: 12, leading: 3
      pdf.move_down 10
    end
    pdf.fill_color MUTED
    pdf.text "Disponibilidade de #{(@catalog.stock_refreshed_at || Time.current).strftime('%d/%m/%Y %H:%M')}", size: 9
    pdf.text 'Para encomendar, use o link (ou QR code) na última página.', size: 9
    pdf.fill_color INK
  end

  def style_section(pdf, style, colors)
    pdf.start_new_page
    pdf.text style.upcase, size: 20, style: :bold
    pdf.fill_color MUTED
    pdf.text "#{colors.size} cor#{'es' if colors.size > 1}", size: 9
    pdf.fill_color INK
    pdf.move_down 12

    width = (pdf.bounds.width - 16 * (COLUMNS - 1)) / COLUMNS
    height = width * 1.25
    colors.each_slice(COLUMNS) do |row|
      pdf.start_new_page if pdf.cursor < height + 60
      top = pdf.cursor
      row.each_with_index do |color, index|
        pdf.bounding_box([index * (width + 16), top], width: width, height: height + 52) { color_cell(pdf, color, width, height) }
      end
      pdf.move_down 16
    end
  end

  def color_cell(pdf, color, width, height)
    image = image_for(color.main_image)
    if image
      pdf.image StringIO.new(image), fit: [width, height], position: :center
    else
      pdf.fill_color MIST
      pdf.fill_rectangle [0, pdf.cursor], width, height
      pdf.fill_color 'C7C7C7'
      pdf.text_box 'CHASE', at: [0, pdf.cursor - height / 2 + 6], width: width, align: :center, size: 12, style: :bold, character_spacing: 4
      pdf.fill_color INK
      pdf.move_down height
    end
    pdf.move_down 6
    pdf.text color.color_name.presence || '—', size: 10, style: :bold
    sizes = color.variants.map do |v|
      next "<color rgb='BDBDBD'>#{v.size}</color>" if v.sold_out?
      next "<color rgb='#{LOW}'>#{v.size}</color>" if v.low?

      v.size
    end
    pdf.text sizes.join('  '), size: 9, inline_format: true
  end

  def closing(pdf)
    pdf.start_new_page
    pdf.move_down 120
    pdf.text 'FAÇA SUA ENCOMENDA', size: 24, style: :bold, align: :center
    pdf.move_down 8
    pdf.fill_color MUTED
    pdf.text 'Aponte a câmera para o QR code ou abra o link abaixo.', size: 11, align: :center
    pdf.fill_color INK
    pdf.move_down 20
    qr = RQRCode::QRCode.new(@public_url).as_png(size: 480, border_modules: 2)
    pdf.image StringIO.new(qr.to_s), width: 220, position: :center
    pdf.move_down 16
    pdf.text @public_url, size: 10, align: :center, color: INK
    pdf.move_down 24
    pdf.fill_color MUTED
    pdf.text 'Tamanhos em laranja: últimas unidades. Em cinza: esgotado no momento.', size: 9, align: :center
    pdf.fill_color INK
  end

  def footer(pdf)
    pdf.repeat(:all) do
      pdf.bounding_box([0, -12], width: pdf.bounds.width, height: 14) do
        pdf.fill_color MUTED
        pdf.text "Chase · #{@catalog.title}", size: 8
        pdf.fill_color INK
      end
    end
    pdf.number_pages '<page>/<total>', at: [pdf.bounds.right - 60, -12], width: 60, align: :right, size: 8, color: MUTED
  end

  # Baixa a foto (Shopify CDN em 600px) e devolve os bytes. Só PNG/JPEG; falha ou formato desconhecido → nil (placeholder).
  def image_for(url)
    return nil if url.blank?
    return @images[url] if @images.key?(url)

    sized = url.include?('cdn.shopify.com') ? "#{url}#{url.include?('?') ? '&' : '?'}width=600" : url
    response = HTTParty.get(sized, timeout: IMAGE_TIMEOUT)
    body = response.body.to_s
    ok = response.code == 200 && (body.start_with?("\x89PNG".b) || body.start_with?("\xFF\xD8".b))
    @images[url] = ok ? body : nil
  rescue StandardError => e
    Rails.logger.error "B2bCatalogPdf image #{url}: #{e.class} #{e.message}"
    @images[url] = nil
  end
end
```

> O cache guarda o corpo (String) e cada uso cria um `StringIO` novo: `pdf.image` lê o IO até o fim.

- [ ] **Step 5: Run tests**

Run: `... bin/rails test test/services/b2b_catalog_pdf_test.rb test/controllers/b2b_catalogs_controller_test.rb`
Expected: PASS. Gerar um PDF de exemplo e conferir visualmente (`qlmanage -t` no PDF).

---

### Task 7: Verificação final e agendamento

- [ ] **Step 1:** Suíte completa num banco novo. Expected: só as 7 falhas preexistentes.
- [ ] **Step 2:** `git status` — só arquivos do plano + `Gemfile`/`Gemfile.lock`.
- [ ] **Step 3:** Passos de produção para o usuário: deploy (migration roda no release); Heroku Scheduler → `bundle exec rake b2b_catalogs:refresh` **a cada 1 hora**; liberar a tela "Catálogos B2B" nos perfis.
