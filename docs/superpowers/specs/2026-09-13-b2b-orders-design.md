# Pedidos B2B (pedido comum + transferência de estoque)

## Contexto

Hoje a criação manual de pedidos no ChaseOrders passa por dois fluxos que não
servem para o caso B2B:

- `OrderPdv` — ponto de venda varejo, com Shopify, cupom, parcelas de
  pagamento; nenhum desses conceitos se aplica a um pedido atacado B2B ou a
  uma transferência de estoque interna.
- `PlannerOrder` — upload de CSV que gera uma **nota fiscal** de transferência
  no Tiny (`CreateNoteTinyJob`, CFOP 5152), mas com o destinatário
  ("cliente" da nota) **hardcoded** no código
  (`app/jobs/create_note_tiny_job.rb`) como "Chase Brasil Comercio de Artigos
  Esportivos Ltda", sempre o mesmo CNPJ.

O objetivo é uma tela nova, dedicada a B2B, onde o usuário monta o pedido
(cliente ou local de destino, transportadora, itens) e decide entre duas
naturezas de operação: um **pedido de venda comum** (vira `pedido` no Tiny)
ou uma **transferência de estoque** (vira `nota fiscal` de transferência no
Tiny, para um local de destino cadastrado pelo próprio usuário — não mais
hardcoded).

## Decisões já tomadas

- Model novo e dedicado (`B2bOrder`), não uma extensão de `OrderPdv` nem de
  `PlannerOrder` — evita misturar conceitos incompatíveis (desconto/cupom/
  parcelas de PDV, ou o CSV-only do Planejador) com um fluxo que tem
  requisitos próprios (tipo de operação, transportadora do Tiny, local de
  transferência com CNPJ).
- Conta do Tiny usada para tudo (pedido, nota fiscal, busca de
  transportadoras): `TOKEN_TINY2_PRODUCTION` (confirmado com o usuário,
  mesma conta que o pipeline "Correios B2B" já usa em
  `DashboardController#order_correios_create_b2b`).
- Transportadora **não** tem cadastro próprio no ChaseOrders — é buscada ao
  vivo na API do Tiny (`formas.envio.pesquisa.php`) e o pedido só guarda o
  nome/forma de envio escolhidos, não um registro local.
- Estoque exibido por item é **informativo apenas** (busca ao vivo no
  Shopify, mesmo padrão de `OrderPdvsController#get_product_stock`); não
  bloqueia envio se a quantidade pedida for maior que o estoque.
- Upload de planilha de itens (colunas SKU + Quantidade) processa em tempo
  real via AJAX — os itens aparecem na tela assim que o arquivo é
  selecionado, sem precisar salvar antes. Itens também podem ser adicionados
  manualmente (busca por SKU/nome), e as duas formas são combináveis.
- Fluxo de status em 4 estados, mesmo padrão do `PlannerOrder`: `draft` →
  `saved` → `transmitted` (ou `error`). "Salvar Rascunho" grava `draft` sem
  nenhuma validação forte; "Salvar" grava `saved` com os campos obrigatórios
  validados; "Transmitir" (botão na listagem e na edição) enfileira o job que
  chama o Tiny e move para `transmitted`/`error`.
- Novas telas entram no sistema de permissões por tela já existente
  (`docs/superpowers/specs/2026-09-13-screen-permissions-design.md`): duas
  novas chaves em `Screen::DEFINITIONS`, `b2b_orders` e `transfer_locations`,
  visíveis em "Perfis e Permissões" para o admin vincular a qualquer perfil.
  Seed inicial: acesso só para o perfil Admin.

## Modelo de dados

### `TransferLocation`

Os locais de destino de transferência — cadastro próprio do ChaseOrders,
usado como `cliente`/`transportador` no payload da nota fiscal do Tiny.

```ruby
create_table :transfer_locations do |t|
  t.string :name, null: false
  t.string :registration, null: false          # CNPJ
  t.string :state_registration                  # IE, opcional
  t.string :street, null: false
  t.string :number, null: false
  t.string :complement
  t.string :neighbourhood, null: false
  t.string :city, null: false
  t.string :state, null: false                   # UF, 2 letras
  t.string :zip, null: false                     # CEP
  t.boolean :active, null: false, default: true
  t.timestamps
end
```

```ruby
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

`dependent: :restrict_with_error` em vez de `destroy`/`nullify`: um local
usado por algum `B2bOrder` (mesmo já transmitido) não pode ser apagado — o
histórico do pedido depende dele.

### `B2bOrder`

```ruby
create_table :b2b_orders do |t|
  t.integer :kind, null: false                   # enum: sale | stock_transfer
  t.integer :status, null: false, default: 0      # enum: draft | saved | transmitted | error
  t.references :client, null: true, foreign_key: true
  t.references :transfer_location, null: true, foreign_key: true
  t.references :user, null: false, foreign_key: true   # quem criou
  t.string :carrier_name                          # nome_transportador (Tiny)
  t.string :carrier_shipping_method                # forma_frete (Tiny)
  t.integer :freight_paid_by                       # enum: shipper | recipient (R/D)
  t.decimal :freight_value, precision: 10, scale: 2
  t.string :tiny_reference_id                      # id do pedido OU da nota fiscal, conforme kind
  t.string :tiny_reference_number
  t.text :error_message
  t.text :notes
  t.timestamps
end
```

```ruby
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

  def transmittable?
    saved? || error?
  end

  private

  def must_have_items
    errors.add(:base, 'Pedido precisa ter pelo menos um item') if b2b_order_items.empty?
  end
end
```

### `B2bOrderItem`

```ruby
create_table :b2b_order_items do |t|
  t.references :b2b_order, null: false, foreign_key: true
  t.string :sku, null: false
  t.string :name
  t.integer :quantity, null: false
  t.decimal :price, precision: 10, scale: 2, null: false
  t.timestamps
end
```

```ruby
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

## Telas e navegação

Nova aba de topo **"Pedidos"** na sidebar
(`app/views/layouts/partials/_sidebar.html.erb`) — **um novo grupo no mesmo
nível hierárquico** dos grupos que já existem lado a lado hoje (`Usuários`,
`CRM`, `Correios B2C`, `Correios B2B`, `Planejador`, `Produtos`): um novo
`<div class="nav-item nav-group-collapsible">` **irmão** desses, dentro do
mesmo `<div class="nav-items">` que os contém, com seu próprio
`toggle...()` de expandir/colapsar (mesmo padrão `onclick="toggleXxx()"` +
`id="xxxDropdown"` que cada grupo já usa) — não fica dentro de "CRM" nem de
nenhum grupo existente. Essa aba nova é **separada** da atual "Pedidos" (o
link que já existe dentro de "CRM", que é só visualização de pedidos
Shopify via `OrdersController` — esse continua existindo, sem mudanças).
Dentro da aba nova "Pedidos":

- **Pedidos B2B** (`b2b_orders_path`) — index + new/edit
- **Locais de Transferência** (`transfer_locations_path`) — CRUD

O grupo "Pedidos" em si só aparece se o usuário tiver acesso a pelo menos
uma das duas telas; cada link dentro dele visível apenas se
`current_user&.can_access_screen?('b2b_orders')` /
`current_user&.can_access_screen?('transfer_locations')` respectivamente
(novo helper de view — hoje o sidebar só checa `current_user&.admin?`
diretamente nos grupos existentes; aqui precisamos checar a permissão de
tela, não só admin, já que o acesso é atribuível a qualquer perfil).

### `Screen::DEFINITIONS` — novas entradas

```ruby
b2b_orders:         'Pedidos B2B',
transfer_locations: 'Locais de Transferência'
```

Seed de dados (nova migration de dados, mesmo padrão da migration de
`screen_permissions`): concede as duas telas só ao perfil Admin (id 1).

### `TransferLocationsController`

CRUD simples, mesmo padrão visual/estrutural do `ProfilesController` já
implementado: `guard_screen :transfer_locations`, index (tabela com
nome/CNPJ/cidade/status/ações), new/edit (formulário com `form-section`),
destroy bloqueado (mensagem de erro) se `transfer_location.b2b_orders.any?`.

### `B2bOrdersController`

`guard_screen :b2b_orders` em todas as ações.

- **`index`**: lista com filtro por status/kind, botão "Transmitir" por
  linha quando `order.transmittable?`.
- **`new`/`edit`**: formulário único —
  1. Rádio "Tipo": Pedido Comum / Transferência de Estoque (JS alterna os
     campos "Cliente" vs "Local de Transferência" sem reload).
  2. Campo condicional: busca de `Client` (pedido comum) OU `select` de
     `TransferLocation.active` (transferência).
  3. Transportadora: `select` populado via **AJAX** —
     `GET b2b_orders/shipping_methods` chama `B2bTinyService#shipping_methods`
     (que chama `formas.envio.pesquisa.php`), retorna JSON `[{name, method}]`
     para popular o dropdown no carregamento da página (cacheado em memória
     do processo por alguns minutos para não bater na API do Tiny a cada
     load — ver seção Integração).
     Junto: frete por conta (rádio remetente/destinatário) e valor do frete
     (opcional).
  4. Itens: upload de planilha (`input type=file`, parse client-side não é
     viável para Excel/CSV genérico — envia via **AJAX** para
     `POST b2b_orders/parse_items_spreadsheet`, que devolve JSON
     `[{sku, name, quantity}]`; o JS injeta as linhas na tabela de itens na
     hora) + botão "Adicionar item" manual (busca por SKU, mesmo padrão de
     `OrderPdvsController#search_product`, sem a parte de preço/variantes
     que não se aplica aqui). Cada linha mostra o estoque Shopify atual do
     SKU (busca AJAX, `GET b2b_orders/product_stock?sku=...`), só
     informativo.
  5. Ações: "Salvar Rascunho" (`status: draft`, sem validar `must_have_items`
     nem cliente/local), "Salvar" (`status: saved`, valida tudo), e — apenas
     se `@b2b_order.transmittable?` — "Transmitir pro Tiny".
- **`transmit`** (member action, POST): só permite se `transmittable?`;
  enfileira `TransmitB2bOrderJob.perform_later(@b2b_order.id)` e redireciona
  com aviso "Pedido enviado para transmissão".

## Integração com o Tiny

### `B2bTinyService` (novo, `app/services/b2b_tiny_service.rb`)

Mesmo padrão estrutural do `TinyService` já existente (POST form-encoded,
token fixo, parse de JSON), mas com token `TOKEN_TINY2_PRODUCTION` e dois
métodos de criação:

```ruby
class B2bTinyService
  BASE_URL = 'https://api.tiny.com.br/api2'.freeze

  def initialize
    @token = ENV.fetch('TOKEN_TINY2_PRODUCTION')
  end

  # GET formas.envio.pesquisa.php — usado para popular o dropdown de transportadora
  def shipping_methods
    response = HTTParty.get("#{BASE_URL}/formas.envio.pesquisa.php",
                             query: { token: @token, formato: 'json' })
    parsed = JSON.parse(response.body).with_indifferent_access
    return [] unless parsed.dig(:retorno, :status) == 'OK'

    Array(parsed.dig(:retorno, :formas_envio)).map do |fe|
      { name: fe.dig(:forma_envio, :nome), method: fe.dig(:forma_envio, :forma_frete) }
    end
  end

  # POST pedido.incluir.php — kind: sale
  def create_sale_order(b2b_order)
    response = do_post('pedido.incluir.php', pedido: build_pedido(b2b_order).to_json)
    parse_pedido_response(response)
  end

  # POST nota.fiscal.incluir.php — kind: stock_transfer
  def create_stock_transfer(b2b_order)
    response = do_post('nota.fiscal.incluir.php', nota: build_nota_fiscal(b2b_order).to_json)
    parse_nota_response(response)
  end

  private

  def do_post(endpoint, body_params)
    HTTParty.post("#{BASE_URL}/#{endpoint}",
                   body: { token: @token, formato: 'json' }.merge(body_params))
  end

  def parse_pedido_response(response)
    retorno = JSON.parse(response.body).with_indifferent_access[:retorno]
    if retorno[:status] == 'OK'
      registro = retorno.dig(:registros, :registro)
      { success: true, tiny_reference_id: registro&.dig(:id)&.to_s, tiny_reference_number: registro&.dig(:numero)&.to_s }
    else
      { success: false, error: Array(retorno.dig(:erros, :erro)).join(', ').presence || 'Erro desconhecido na API Tiny' }
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

#### `shipping_methods` — `formas.envio.pesquisa.php`

Retorna a lista de formas de envio/transportadoras já cadastradas na conta
Tiny 2. Usado só para popular o `select` — nenhum dado é persistido além do
nome/método escolhido no próprio `B2bOrder`. Cacheado em `Rails.cache` por
alguns minutos (`Rails.cache.fetch('tiny2_shipping_methods', expires_in: 10.minutes)`)
para não bater na API a cada carregamento de formulário.

#### `create_sale_order` — `pedido.incluir.php` (kind: sale)

Reaproveita o mapeamento de cliente que `TinyService#build_pedido` já faz
para `client` (nome, tipo_pessoa, cpf_cnpj, endereço), adaptado para
`B2bOrder#client`:

```ruby
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
```

Resposta: `{success: true, tiny_reference_id:, tiny_reference_number:}` ou
`{success: false, error:}` — mesmo shape (campos renomeados para serem
comuns aos dois `kind`s) de `TinyService#create_order`.

#### `create_stock_transfer` — `nota.fiscal.incluir.php` (kind: stock_transfer)

Reaproveita a estrutura de `CreateNoteTinyJob#mount_note`, mas o bloco
`cliente` vem do `TransferLocation` escolhido em vez de hardcoded, e inclui
o objeto `transportador`:

```ruby
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
```

Resposta processada igual `CreateNoteTinyJob#process_response`:
`tiny_reference_id`/`tiny_reference_number` = `numero` da nota, status
`transmitted` se `status_processamento == '3' && status == 'OK'`, senão
`error` com a mensagem do Tiny.

### `TransmitB2bOrderJob`

```ruby
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

### Estoque ao vivo (Shopify)

`B2bOrdersController#product_stock` reaproveita exatamente o padrão de
`OrderPdvsController#get_product_stock` (GraphQL `productVariant.inventoryQuantity`
por `shopify_variant_id`), retornando `{quantity, status, message}` por SKU.
Chamado via AJAX por linha de item, só para exibição — não valida nem
bloqueia.

## Upload de planilha de itens

`B2bOrdersController#parse_items_spreadsheet` (POST, AJAX): recebe o
arquivo, faz parse (CSV, mesmo padrão de `PlannerOrdersController#process_csv`
— colunas SKU e Quantidade; aceitar `.csv`; `.xlsx` fica fora de escopo
inicial já que não há precedente de leitura de xlsx no código, só escrita
via `RubyXL` em `export_xlsx`), retorna JSON com os itens encontrados
(nome resolvido via `Product.find_by(sku:)`, preço vazio — usuário preenche
manualmente, já que a planilha só tem SKU/Quantidade). O JS injeta as linhas
na tabela de itens do formulário sem precisar salvar o pedido antes.

## Testes

- `test/models/transfer_location_test.rb`: validações (CNPJ, endereço),
  `dependent: :restrict_with_error` quando há `b2b_orders` vinculados.
- `test/models/b2b_order_test.rb`: validação condicional de `client`/
  `transfer_location` por `kind`, `must_have_items` (exceto em `draft`),
  `transmittable?`.
- `test/controllers/transfer_locations_controller_test.rb`: CRUD, guard de
  tela, bloqueio de destroy com pedidos vinculados.
- `test/controllers/b2b_orders_controller_test.rb`: guard de tela, criar
  rascunho sem itens, criar `saved` validando itens/cliente/local, ação
  `transmit` só quando `transmittable?`.
- `test/services/b2b_tiny_service_test.rb`: o projeto não tem nenhuma
  biblioteca de mock de HTTP hoje (`webmock`/`vcr` ausentes do Gemfile) — a
  implementação adiciona `gem 'webmock', group: :test` e usa
  `stub_request` para os três métodos (`shipping_methods`,
  `create_sale_order`, `create_stock_transfer`), sem bater na API real do
  Tiny durante a suíte.

## Fora do escopo (não mexer)

- `OrderPdv`, `PlannerOrder`, `CreateNoteTinyJob` e o pipeline "Correios B2B"
  continuam existindo e funcionando exatamente como hoje — nada aqui os
  substitui ou altera.
- Cadastro de transportadora no ChaseOrders (CRUD próprio) — decidido buscar
  ao vivo do Tiny em vez disso.
- Bloqueio/validação de estoque insuficiente — só exibição informativa.
- Leitura de planilha `.xlsx` — só `.csv` no primeiro momento, mesmo padrão
  do `PlannerOrder`.
