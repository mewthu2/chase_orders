# Sistema de Perfis e Permissões por Tela

## Contexto

Hoje o controle de acesso do ChaseOrders é feito por checagens de perfil
hardcoded espalhadas pelos controllers (`admin_only!`, `admin_or_manager!`,
`require_admin!`, `check_marketing_access`, `check_admin_marketing_access`,
`admin_required`), todas baseadas em IDs fixos de `Profile`
(`ADMIN = 1`, `MANAGER = 2`, `USER = 3`, `ADMIN_MARKETING = 5`,
`AGENT_MARKETING = 6`). Não existe tela para criar perfis nem para decidir,
sem alterar código, quais telas cada perfil pode acessar.

O objetivo é substituir essas checagens por um sistema dinâmico:
administradores criam perfis e marcam, por perfil, quais telas ele acessa.

## Decisões já tomadas

- Granularidade: acesso simples por tela (sim/não), sem distinção por ação
  (ver/criar/editar/excluir) dentro da tela.
- Escopo: migrar **todas** as checagens de perfil existentes hoje para o
  novo sistema (não é uma camada adicional por cima das antigas).
- Lista de telas: curada manualmente (nomes de negócio), não uma entrada
  automática por controller.

## Modelo de dados

Nova tabela `screen_permissions`, uma linha = "este perfil acessa esta tela":

```ruby
create_table :screen_permissions do |t|
  t.references :profile, null: false, foreign_key: true
  t.string :screen_key, null: false
  t.timestamps
end
add_index :screen_permissions, [:profile_id, :screen_key], unique: true
```

Não existe tabela `screens`. A lista de telas é uma constante em código
(`app/models/screen.rb`), porque toda tela precisa estar amarrada a um
`before_action` em um controller de qualquer forma — uma tabela editável
não eliminaria a necessidade de deploy para telas novas. Se no futuro for
necessário permissão por ação, ou telas 100% dinâmicas, essa constante vira
o ponto de extensão natural.

```ruby
class Screen
  DEFINITIONS = {
    users_management:       'Gerenciar Usuários',
    orders:                 'Pedidos',
    customers:              'Clientes',
    discounts:               'Descontos',
    logs:                    'Logs',
    dashboard_correios:      'Painel de Correios',
    marketing_campaigns:     'Campanhas de Marketing',
    marketing_tasks:         'Tarefas de Marketing'
  }.freeze

  def self.keys = DEFINITIONS.keys.map(&:to_s)
  def self.options_for_select = DEFINITIONS.map { |k, v| [v, k.to_s] }
  def self.label(key) = DEFINITIONS[key.to_sym]
end
```

### Model changes

`Profile`:
```ruby
has_many :screen_permissions, dependent: :destroy

def can_access?(screen_key)
  screen_permissions.exists?(screen_key: screen_key.to_s)
end

def screen_keys
  screen_permissions.pluck(:screen_key)
end

def screen_keys=(keys)
  clean = Array(keys).reject(&:blank?) & Screen.keys
  self.screen_permissions = clean.map { |k| screen_permissions.find_or_initialize_by(screen_key: k) }
end
```
Using the `screen_keys=` writer with `screen_permissions =` lets a single
`profile.update(screen_keys: params[...])` replace the whole permission set
in one call (Rails diffs and persists the association).

`User`:
```ruby
def can_access_screen?(screen_key)
  admin? || profiles.any? { |p| p.can_access?(screen_key.to_s) }
end
```
Remove `can_access_feature?` (dead code — not called anywhere; this feature
replaces it).

### ApplicationController

```ruby
def self.guard_screen(key, **options)
  before_action(**options) { authorize_screen!(key) }
end

private

def authorize_screen!(screen_key)
  return if current_user&.can_access_screen?(screen_key)
  redirect_to root_path, alert: 'Acesso negado.'
end
```

## Mapeamento de telas existentes → seed de dados

Cada controller abaixo troca seu guard atual por `guard_screen :key`. Uma
migração de dados (`db/migrate/..._seed_screen_permissions.rb` ou uma task
em `db/seeds.rb` rodada uma vez) grava as permissões abaixo para os 5
perfis já existentes, para que **nenhum usuário perca acesso no deploy**:

| Tela (`screen_key`) | Controller | Guard atual substituído | Perfis com acesso no seed |
|---|---|---|---|
| `users_management` | `UsersController` | `admin_required` (except edit/update) | Admin |
| `orders` | `OrdersController` | `require_admin!` | Admin, Admin Marketing, Agente Marketing |
| `customers` | `CustomersController` | `require_admin!` | Admin, Admin Marketing, Agente Marketing |
| `discounts` | `DiscountsController` | `admin_or_manager!` | Admin, Gerente |
| `logs` | `LogsController` | `admin_only!` | Admin |
| `dashboard_correios` | `DashboardController` | `admin_only!` | Admin |
| `marketing_campaigns` | `MarketingCampaignsController` | `check_admin_marketing_access` | Admin, Admin Marketing |
| `marketing_tasks` | `MarketingTasksController` | `check_marketing_access` | Admin, Admin Marketing, Agente Marketing |

Perfis novos criados pela UI começam **sem nenhuma tela marcada** — o admin
tem que marcar explicitamente.

### Fora do escopo (não mexer)

- `UsersController#edit`/`#update`: continuam permitindo o próprio usuário
  editar seu registro (`check_user_permission`), sem relação com telas.
- `DiscountsController#logs`/`#sync`: continuam com o `admin_only!`
  hardcoded adicional que já existia (mais restritivo que o resto de
  Descontos); não vira parte do sistema de telas para não afrouxar o
  controle atual com a granularidade "tela inteira".
- Controllers sem guard de perfil hoje (estoque, produtos, PDV, planejador,
  motores, clientes-pedido, etc.) permanecem abertos a qualquer usuário
  autenticado — este trabalho migra o que já era restrito, não introduz
  restrições novas.
- Regras de negócio que usam `admin?`/`manager?` fora de controle de tela
  (ex.: em `StockCorrectionsController`, quem pode reabrir/excluir uma
  correção já executada; escopo de `allowed_locations`) continuam como
  estão — não são "acesso a uma tela", são regras de fluxo.

## UI

Novo `ProfilesController` (CRUD), rota `resources :profiles`, protegido
por `before_action :admin_only!` (o guard hardcoded que já existe em
`ApplicationController` — faz sentido que gerenciar perfis continue
admin-only fixo, já que é quem concede os próprios acessos).

- **`index`**: lista de perfis (nome, descrição, ativo, quantidade de
  usuários). Botões novo/editar/excluir.
- **`new` / `edit`**: um único formulário com os campos de
  nome/descrição/ativo e uma lista de checkboxes, uma por
  `Screen::DEFINITIONS`, agrupada em uma seção "Telas Permitidas" (mesmo
  padrão visual de `form-section` usado em `users/_form.html.erb`).
- **`destroy`**: bloqueado (`redirect_to profiles_path, alert: ...`) se o
  perfil ainda tiver usuários vinculados (`profile.users.any?`), para
  evitar usuário sem nenhum perfil (violaria a validação
  `must_have_at_least_one_profile` de forma silenciosa via cascade).

### Navegação

Novo link "Perfis e Permissões" dentro do dropdown "Usuários" da sidebar
(`app/views/layouts/partials/_sidebar.html.erb`), visível só para
`current_user&.admin?`, ao lado do link existente "Gerenciar Usuários".
Nome escolhido para não confundir com "Meu Perfil" (que se refere à conta
do próprio usuário, sentido diferente de "perfil" já usado no app).

## Testes

- `test/models/profile_test.rb` (novo): `can_access?`, `screen_keys=`.
- `test/models/user_test.rb`: adicionar casos para `can_access_screen?`
  (admin bypass, perfil com/sem a tela).
- `test/controllers/profiles_controller_test.rb` (novo): CRUD, bloqueio de
  admin-only, bloqueio de destroy com usuários vinculados.
- Para cada controller migrado, ajustar/objetos de teste existentes que
  dependiam do guard antigo, se houver, para continuarem passando com o
  novo `guard_screen`.

## Migração de dados — ordem de execução

1. Migration cria `screen_permissions`.
2. Seed (task ou migration de dados) grava as permissões da tabela de
   mapeamento acima para os 5 perfis existentes.
3. Só depois disso os controllers trocam para `guard_screen`, para não
   haver uma janela em que os perfis existentes fiquem sem nenhuma
   permissão gravada.
