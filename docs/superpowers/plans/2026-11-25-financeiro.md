# Financeiro (Etapa 1) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Área Financeiro (conferência de recebimento dos pedidos de atacado com baixa por parcela de boleto, cadastro de consultores, percentuais por mês e comissões calculadas na hora), mais o número do Tiny fora das telas do atacado e a home sem chamados, com busca central.

**Architecture:** Três tabelas novas (`consultants`, `b2b_order_payments`, `commission_rates`) e `b2b_orders.consultant_id`. As parcelas de boleto são sincronizadas a partir de `B2bOrder#installments` num callback; a comissão é um serviço puro (`Finance::Commissions`) que lê pedidos + parcelas + percentuais do mês, sem gravar nada. Telas no padrão `HoneyTable`/`hc_pg_table` com filtro `:month`, protegidas por `guard_screen` com chaves novas numa área `financeiro` de `Screen`.

**Tech Stack:** Rails 8.1, Ruby 4.0, MySQL 8, Minitest + integration tests, HoneyTable, Stimulus/importmap.

**Spec:** `docs/superpowers/specs/2026-11-25-financeiro-design.md`

## Global Constraints

- Base da comissão: `B2bOrder#grand_total` (produtos com desconto + frete). Só `kind: sale`, `status != cancelado`.
- Vale desde sempre: todos os pedidos `sale` entram; migração de backfill gera as parcelas do histórico.
- Digitador (`b2b_orders.user_id`): comissão no mês de `created_at` do pedido, sem esperar pagamento.
- Consultor: PIX e cartão (mesmo parcelado) = pago em `created_at`, total no mês do pedido. Boleto (ou sem forma de pagamento) = cada parcela no mês do seu `paid_at`, `amount × %`.
- Pedido sem `payment_method` = boleto à vista: 1 parcela, vencimento = data do pedido.
- Percentual: por mês (date dia 1) e por pessoa; ausência = 0% e aviso "sem percentual". Copiar do mês anterior só por ação explícita (POST); nenhum GET grava.
- Consultor só com nome (sem `consultant_id`): aparece pelo nome com "cadastro pendente", 0%.
- Acesso: área `financeiro` só para admins e para o perfil "Financeiro" (usuário financeiro@chasebrasil.com).
- Banco de dev = produção: **nunca** rodar `db:migrate` local; migrações só aditivas e seguras para rodar a qualquer hora; testar no MySQL temporário (ver memória do projeto). Ajustes de dados via `update_columns`, sem callbacks/e-mail.
- **Não commitar** (preferência do usuário): ignore os passos de commit; deixe as mudanças no working tree.
- Textos da UI em português; visual vivo/animado do Honey.

## Review Focus

1. Editar um pedido de boleto já com parcela paga (mudar itens/frete/prazos): parcelas pagas permanecem intactas, as não pagas são refeitas sobre o saldo (`grand_total − soma paga`).
2. Trocar a forma de pagamento de boleto para PIX depois de ter parcela paga: as parcelas pagas ficam (não somem do histórico) e as pendentes são apagadas; comissão do consultor passa a ser o total no mês do pedido, sem contar duas vezes.
3. Cancelar um pedido com parcela já baixada: some das comissões e dos totais "a receber"; a parcela continua registrada.
4. Percentual mudado em dezembro não altera a comissão exibida de novembro.
5. Vincular um nome pendente ("Ana") a um consultor cadastrado atualiza todos os pedidos com aquele nome (comparação sem caixa/acentos nas pontas, `strip` + `casecmp`), e a comissão passa a usar o % do cadastro.

---

## File Structure

**Create**
- `db/migrate/20261125120000_create_finance_tables.rb` — consultants, b2b_orders.consultant_id, b2b_order_payments, commission_rates
- `db/migrate/20261125120100_backfill_b2b_order_payments_and_finance_profile.rb` — parcelas do histórico + perfil Financeiro para financeiro@chasebrasil.com
- `app/models/consultant.rb`, `app/models/b2b_order_payment.rb`, `app/models/commission_rate.rb`
- `app/services/finance/payment_schedule.rb` — sincroniza parcelas de um pedido
- `app/services/finance/commissions.rb` — cálculo do mês
- `app/controllers/finance/orders_controller.rb`, `finance/payments_controller.rb`, `finance/consultants_controller.rb`, `finance/commissions_controller.rb`
- `app/views/finance/orders/index.html.erb`, `finance/consultants/{index,_form,new,edit}.html.erb`, `finance/commissions/{index,show}.html.erb`
- Tests: `test/models/b2b_order_payment_test.rb`, `test/services/finance/payment_schedule_test.rb`, `test/services/finance/commissions_test.rb`, `test/controllers/finance/{orders,payments,consultants,commissions}_controller_test.rb`

**Modify**
- `app/models/b2b_order.rb` (belongs_to consultant, has_many payments, callback)
- `app/models/screen.rb`, `app/models/navigation.rb`, `config/honey/help.json`, `config/routes.rb`
- `app/controllers/b2b_orders_controller.rb` + `app/views/b2b_orders/_form.html.erb` (Consultor)
- `app/views/b2b_orders/index.html.erb`, `app/views/dashboard/*_b2b*.erb`, `app/views/dashboard/_honey_b2b_orders.html.erb` (tirar Nº Tiny)
- `app/controllers/home_controller.rb`, `app/views/home/index.html.erb`, `app/javascript/honey_shell.js` (home com busca), Navigation (esconder chamados)
- `test/controllers/home_controller_test.rb` (substituir pelos testes da nova home)

---

### Task 1: Tabelas, modelos e parcelas do pedido

**Files:** migration `20261125120000`, `consultant.rb`, `b2b_order_payment.rb`, `commission_rate.rb`, `b2b_order.rb`, `finance/payment_schedule.rb`, tests `b2b_order_payment_test.rb`, `payment_schedule_test.rb`

**Interfaces — Produces:**
- `Consultant(name:string!, document, phone, email, pix_key, active:bool=true)`; `has_many :b2b_orders, dependent: :nullify`; `scope :active`; `scope :ordered` (by name).
- `B2bOrder belongs_to :consultant, optional: true`; `has_many :payments, class_name: 'B2bOrderPayment', dependent: :destroy`; `B2bOrder#consultant_label -> String|nil` (`consultant&.name || salesperson_name.presence`); `B2bOrder#consultant_pending? -> bool` (nome sem cadastro); `B2bOrder#paid_on_creation? -> bool` (`%w[pix cartao].include?(payment_method)`).
- `B2bOrderPayment(b2b_order_id, number:int, due_date:date, amount:decimal(12,2), paid_at:date, paid_by_id→users)`; scopes `paid`, `pending`, `overdue(today = Date.current)` (pending and due_date < today); `#paid?`.
- `CommissionRate(month:date, beneficiary:polymorphic User|Consultant, percent:decimal(5,2))`, unique `[month, beneficiary_type, beneficiary_id]`; `CommissionRate.for_month(date) -> Hash{[type,id] => BigDecimal}`; `CommissionRate.copy_previous!(month) -> Integer` (copia do mês mais recente anterior que tenha linhas, só pessoas ainda sem linha no mês; devolve quantas criou).
- `Finance::PaymentSchedule.call(order)` — sincroniza `order.payments`.
- `B2bOrder after_save :sync_payments, if: :sale?` → `Finance::PaymentSchedule.call(self)` quando mudou `payment_method`, `payment_terms`, `freight_value`, `order_discount*`, `status` ou itens (chamar também após salvar itens no controller, se os itens salvam fora do pedido).

**Algoritmo de `PaymentSchedule` (o que os testes fixam):**
- Pedido `pix`/`cartao`: apaga parcelas **pendentes**; mantém as pagas.
- Boleto ou sem forma: dias = `installment_days` ou `[0]` se vazio. Saldo = `grand_total − soma(paid.amount)`. Parcelas pagas ficam; as pendentes são refeitas para os dias que ainda não têm parcela paga (por `number`), dividindo o saldo igual (última com a sobra de centavos), `due_date = created_at.to_date + dias`. Se saldo ≤ 0, nenhuma pendente.
- Pedido cancelado: não mexe em nada.

- [ ] **Step 1: Write failing tests**

```ruby
# payment_schedule_test.rb
test 'boleto 30 60 90 gera tres parcelas que somam o total com frete'  # grand_total 300 + frete 33.33 → [111.11,111.11,111.11]; due_dates +30/+60/+90
test 'sem forma de pagamento gera uma parcela vencendo na data do pedido'
test 'pix nao gera parcela'
test 'editar valor refaz so as pendentes sobre o saldo'  # 300 em 3x, paga a 1ª (100), total vira 420 → pendentes 160 e 160
test 'trocar boleto por pix apaga pendentes e mantem pagas'
test 'pedido cancelado nao mexe nas parcelas'
# b2b_order_payment_test.rb
test 'overdue so traz pendentes vencidas'
test 'CommissionRate.copy_previous! copia do ultimo mes com linhas e nao sobrescreve'
```

- [ ] **Step 2:** Rodar no MySQL temporário: `TEST_DATABASE_URL=mysql2://root@127.0.0.1:3390/<banco_novo> PARALLEL_WORKERS=1 bin/rails test test/services/finance/payment_schedule_test.rb test/models/b2b_order_payment_test.rb` → FAIL (tabelas/classes inexistentes).
- [ ] **Step 3:** Migração (aditiva: `create_table` com `if_not_exists: true`, `add_reference :b2b_orders, :consultant, if_not_exists: true`), modelos, callback e serviço. Regerar `db/schema.rb` num banco limpo separado (não no dev).
- [ ] **Step 4:** Mesmos testes → PASS; rodar `test/controllers/b2b_orders_controller_test.rb` para garantir que o callback não quebrou o fluxo atual.

### Task 2: Backfill e perfil Financeiro

**Files:** migration `20261125120100`, test `test/migrations/backfill_finance_test.rb` (ou teste do método de classe usado pela migração)

**Interfaces — Produces:** `Finance::PaymentSchedule.backfill! -> Integer` (percorre `B2bOrder.sale.where.not(status: :cancelado).where.missing(:payments)` em lotes e chama `call`; devolve quantos pedidos). Perfil `Profile.find_or_create_by!(name: 'Financeiro')` com `screen_permissions` `finance_orders: 'VE'`, `consultants: 'VCED'`, `commissions: 'VEP'`; vincula ao `User.find_by(email: 'financeiro@chasebrasil.com')` se existir (sem e-mail, via `UserProfile.find_or_create_by!`).

- [ ] **Step 1:** Teste: `backfill!` cria parcelas para pedido boleto sem parcelas, ignora pix, cancelados e pedidos que já têm parcelas; rodar duas vezes não duplica.
- [ ] **Step 2:** FAIL → implementar → PASS. A migração chama `backfill!` e o seed do perfil com `reset_column_information`; tudo idempotente. Depende da Task 4 para as chaves de `Screen` (rodar Task 4 antes desta, ou adicionar as chaves já aqui).

### Task 3: Cálculo das comissões

**Files:** `app/services/finance/commissions.rb`, `test/services/finance/commissions_test.rb`

**Interfaces — Produces:**
```ruby
Finance::Commissions.new(month: Date).rows
# => [Row(role: :typist|:consultant, key: "User:1"|"Consultant:3"|"name:ana",
#         name:, beneficiary: User|Consultant|nil, pending: bool, percent: BigDecimal|nil,
#         base: BigDecimal, commission: BigDecimal, entries: [Entry(order:, payment: B2bOrderPayment|nil, date:, base:)])]
Finance::Commissions.new(month:).totals  # => { base:, commission: }
```
Regras: digitadores = pedidos `sale` não cancelados com `created_at` no mês, agrupados por `user`. Consultores = (a) pedidos `paid_on_creation?` com `created_at` no mês, base `grand_total`; (b) parcelas `paid_at` no mês de pedidos não cancelados, base `amount`. Agrupa por `consultant_id`, ou por nome normalizado (`salesperson_name.strip.downcase`) quando sem cadastro. Pedido sem consultor nem nome não entra na parte de consultor. `percent` de `CommissionRate.for_month(month)`; pendente/sem linha → `nil`, comissão 0. Arredondar comissão por linha a 2 casas. Ordenar: digitadores, depois consultores, por nome. Sem N+1 (`includes(:user, :consultant, :b2b_order_items)` e pedidos das parcelas).

- [ ] **Step 1:** Testes:
```ruby
test 'digitador recebe sobre o total com frete no mes do pedido'      # 300+30 frete, 2% → 6.60
test 'consultor de pix recebe o total no mes do pedido'
test 'boleto 3x so conta as parcelas pagas, no mes do pagamento'     # paga 1ª em nov e 2ª em dez → nov 1/3, dez 1/3
test 'pedido cancelado nao entra'
test 'nome sem cadastro aparece como pendente com comissao zero'
test 'percentual de outro mes nao afeta o mes'
```
- [ ] **Step 2:** FAIL → implementar → PASS.

### Task 4: Área Financeiro no menu e permissões

**Files:** `screen.rb`, `navigation.rb`, `config/honey/help.json`, `config/routes.rb`, test em `test/controllers/finance/orders_controller_test.rb`

**Interfaces — Produces:**
- `Screen::AREAS['financeiro'] = { title: 'Financeiro', icon: 'fas fa-sack-dollar', color: '#2ea043', desc: 'Recebimentos do atacado, consultores e comissões.' }` (inserir antes de `adm`).
- `Screen::DEFINITIONS`: `finance_orders: { label: 'Financeiro · Pedidos de Atacado', area: 'financeiro', acts: 'VE' }`, `consultants: { label: 'Financeiro · Consultores', area: 'financeiro', acts: 'VCED' }`, `commissions: { label: 'Financeiro · Comissões', area: 'financeiro', acts: 'VEP' }`.
- Rotas em `namespace :finance, path: 'financeiro'`: `resources :orders, only: :index, path: 'pedidos'`; `resources :payments, only: [] { member { patch :pay; patch :unpay } }` + `collection { patch :pay_many }` (path `parcelas`); `resources :consultants, path: 'consultores', except: :show { collection { post :link_name } }`; `resources :commissions, only: [:index], path: 'comissoes' { collection { get ':key', action: :show, as: :person; post :rates; post :copy_previous } }`.
- Navigation: `area('financeiro', [link('fin-pedidos', 'Pedidos de Atacado', 'fas fa-file-invoice-dollar', 'Recebimentos: PIX e cartão pagos, boletos parcela a parcela.', perm: 'finance_orders' ...), link('fin-comissoes', 'Comissões', 'fas fa-percent', ...), link('fin-consultores', 'Consultores', 'fas fa-id-badge', ...)])`, com entradas no `help.json`.

- [ ] **Step 1:** Teste: usuário sem perfil financeiro recebe redirect em `finance_orders_path`; usuário com perfil Financeiro e admin recebem 200; menu do usuário comum não mostra a área.
- [ ] **Step 2:** FAIL → implementar (controllers vazios com `guard_screen`) → PASS; rodar `test/controllers/honey_pages_render_test.rb`.

### Task 5: Tela Pedidos de Atacado (Financeiro) e baixa de parcelas

**Files:** `finance/orders_controller.rb`, `finance/payments_controller.rb`, `views/finance/orders/index.html.erb`, tests

**Interfaces — Consumes:** Task 1 (`payments`, `paid_on_creation?`, `consultant_label`, `consultant_pending?`).
**Produces:** `PATCH pay` (param `paid_at`, padrão hoje; grava `paid_by: current_user`), `PATCH unpay`, `PATCH pay_many` (`ids[]`, `paid_at`); todas exigem `finance_orders` 'E' (`guard_screen :finance_orders, actions: { pay: :edit, unpay: :edit, pay_many: :edit }`); recusam parcela de pedido cancelado.

Tela: `HoneyTable` com uma linha por pedido `sale` (filtro `:month` por `created_at`, padrão mês atual, aceita "todos"; filtros de situação `pago|pendente|vencido` e forma de pagamento; busca por nº/cliente/consultor). Colunas: nº, data, cliente, consultor (selo "cadastro pendente"), digitador, total com frete, forma (`payment_description`), situação. Detalhe da linha: parcelas com vencimento, valor, situação e botões Baixar/Desfazer. KPIs: Recebido, A receber, Vencido (somas das parcelas + pix/cartão como recebidos). Seleção múltipla de parcelas pendentes + data → `pay_many`. Situação do pedido: cancelado → fora da lista (aba "Cancelados" opcional); pix/cartão → "Pago"; boleto → "Pago" se todas pagas, "Vencido" se alguma pendente vencida, senão "Pendente".

- [ ] **Step 1:** Testes: lista mostra pix como Pago e boleto como Pendente; `pay` grava `paid_at`/`paid_by`; `unpay` limpa; `pay_many` baixa só pendentes dos ids; usuário com só 'V' recebe redirect no `pay`; parcela de pedido cancelado não é baixada.
- [ ] **Step 2:** FAIL → implementar → PASS.

### Task 6: Consultores e o campo Consultor no pedido

**Files:** `finance/consultants_controller.rb`, views, `b2b_orders_controller.rb`, `b2b_orders/_form.html.erb`, `b2b_orders/index.html.erb`, tests

**Interfaces — Produces:** `POST link_name` (`name`, `consultant_id` ou `create=1`): cria o consultor se pedido e faz `B2bOrder.sale.where(consultant_id: nil).where('LOWER(TRIM(salesperson_name)) = ?', name.strip.downcase).update_all(consultant_id:, salesperson_name: consultant.name)`. Lista de "nomes pendentes": distintos de `salesperson_name` sem `consultant_id` com contagem de pedidos.

Form do pedido: o campo "Vendedor" vira "Consultor": `<input list>` (datalist dos `Consultant.active.ordered`) com `salesperson_name` + hidden `consultant_id` preenchido via JS quando o texto bate exatamente com um nome da lista; no controller, se `consultant_id` vier e o nome não bater com o cadastro, zera `consultant_id`. Permitir `:consultant_id` nos params. Lista de pedidos: coluna "Vendedor" vira "Consultor" com selo de pendente.

- [ ] **Step 1:** Testes: CRUD de consultores com perfil Financeiro; `link_name` vincula todos os pedidos de "ana " e "Ana"; criar pedido escolhendo consultor grava `consultant_id`; digitar nome livre grava só `salesperson_name`.
- [ ] **Step 2:** FAIL → implementar → PASS; rodar `test/controllers/b2b_orders_controller_test.rb`.

### Task 7: Tela de Comissões

**Files:** `finance/commissions_controller.rb`, `views/finance/commissions/{index,show}.html.erb`, test

**Interfaces — Consumes:** Task 3 (`Finance::Commissions`), Task 1 (`CommissionRate`).
**Produces:** `index` (param `mes=AAAA-MM`, padrão atual, setas de mês): tabela de `rows` com papel, nome (+ selo pendente), % (input editável se `screen_can?(:commissions, :edit)` e beneficiário cadastrado), base, comissão; KPIs total base/comissão; botão "Copiar do mês anterior" (POST `copy_previous`); formulário salva `rates` (`percents[User:1]=2.5`) via `CommissionRate.upsert` por linha (vazio apaga a linha). `show` (`:key` = `User-1`/`Consultant-3`/`name-ana`): entradas do mês (pedido, cliente, data, parcela n/total, base). Export CSV em `index.csv` (letra P).

- [ ] **Step 1:** Testes: index lista digitador e consultor com valores da Task 3; POST rates grava e só no mês do param; GET de mês vazio não cria `CommissionRate`; `copy_previous` copia; CSV com cabeçalho `Papel;Nome;Percentual;Base;Comissão`.
- [ ] **Step 2:** FAIL → implementar → PASS.

### Task 8: Sem número do Tiny no atacado

**Files:** `app/views/b2b_orders/index.html.erb` (coluna `:tiny` `Nº Tiny`, busca por `tiny_reference_number`, textos "Já no Tiny"), `app/views/dashboard/send_xml_b2b.html.erb`, `push_tracking_b2b.html.erb` (tabelas "Pedidos antigos do Tiny 2"), `_honey_b2b_orders.html.erb`, demais filas do Log02 que exibem `tiny_reference_*`.

Remover só da tela (colunas, busca, blocos "pedidos antigos do Tiny 2" e textos que falam em Tiny para o atacado). Não apagar colunas do banco nem lógica de modelo.

- [ ] **Step 1:** Teste em `b2b_orders_controller_test`: index de atacado não contém "Nº Tiny"; em `honey_b2b_log_screens_test`: filas do Log02 não contêm "Tiny 2".
- [ ] **Step 2:** FAIL → remover → PASS; `grep -rn "tiny_reference" app/views/b2b_orders app/views/dashboard/*b2b*` só sobra lógica que não aparece na tela.

### Task 9: Home sem chamados, com busca central

**Files:** `navigation.rb` (remover a área `geral`→ grupo `chamados` do menu; manter whatsapp), `home_controller.rb`, `views/home/index.html.erb`, `honey_shell.js`, `test/controllers/home_controller_test.rb`

**Interfaces — Consumes:** `NavigationHelper#nav_search_data`.
`HomeController#index` deixa de carregar chamados; a view mostra saudação + campo grande "O que você precisa hoje?" que filtra a mesma lista do Ctrl+K (reusar a função de busca do `honey_shell.js`, exportando `renderPaletteResults(container, query)` ou abrindo a paleta embutida) e abaixo os atalhos das telas que o usuário pode abrir, por área. Rotas dos chamados (`tickets`, `root_path(scope:)`) continuam respondendo por URL: mover o painel antigo para `tickets#dashboard` em `/chamados` sem link no menu. Badge `:waiting_me` sai do topo.

- [ ] **Step 1:** Reescrever `home_controller_test.rb`: `get root_path` → 200, contém "O que você precisa hoje?", não contém "Meus chamados"; menu não tem "Abrir chamado"; `/chamados` ainda responde 200 para quem tinha acesso.
- [ ] **Step 2:** FAIL → implementar → PASS; rodar `honey_pages_render_test.rb`.

### Task 10: Verificação final

- [ ] Suíte inteira no MySQL temporário (banco novo): comparar com baseline (12 falhas + 7 erros pré-existentes); nenhuma falha nova.
- [ ] `bin/rails assets:precompile` + `touch tmp/restart.txt` e olhar as telas novas no localhost:3000 (só leitura) ou no servidor de demonstração.
- [ ] Não commitar; listar ao usuário as migrações pendentes (rodam no deploy).
