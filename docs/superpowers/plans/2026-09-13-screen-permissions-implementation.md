# Sistema de Perfis e Permissões por Tela — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hardcoded per-controller admin/manager/marketing guards with a dynamic screen-permission system driven by `Profile` records, and expose a "Perfis e Permissões" screen (admin-only) under the "Usuários" sidebar menu to manage it.

**Architecture:** New `screen_permissions` join table (`profile_id` + `screen_key`) backs a curated `Screen` constant list. `Profile#can_access?` / `User#can_access_screen?` replace the old `admin?`/`manager?`/`marketing_profile?` checks in controllers. A `ApplicationController.guard_screen` class-level helper installs a `before_action` that calls the new authorization check. A data migration seeds today's real access (by profile) into the new table so no user loses access on deploy. A new `ProfilesController` (CRUD, admin-only) lets admins edit which screens each profile can see, with a sidebar link visible only to `current_user&.admin?`.

**Tech Stack:** Rails 7.2.2, MySQL (schema uses `utf8mb4_0900_ai_ci`), Minitest + fixtures, Devise 4.9.4.

**Spec:** `docs/superpowers/specs/2026-09-13-screen-permissions-design.md`

## Global Constraints

- Granularity is screen-level only (yes/no access), no per-action (view/create/edit/delete) distinction.
- This migrates **all** existing hardcoded profile checks in controllers — it is not an additional layer on top of the old ones. Every guard listed in the mapping table below must be removed, not left in place alongside the new one.
- The screen list is a manually curated Ruby constant (`app/models/screen.rb`), not a DB table — there is no `screens` table.
- The seed migration must run, and controllers must be migrated to `guard_screen`, in that order — never the reverse (a window where controllers reject everyone).
- New profiles created via the UI start with **zero** screens checked; nothing is auto-granted.
- `ProfilesController` stays behind the existing hardcoded `admin_only!` (from `ApplicationController`), not `guard_screen` — managing profiles/permissions must not itself be governed by the permission system it edits.
- Out of scope, do not touch: `UsersController#edit`/`#update`'s `check_user_permission`; `DiscountsController#logs`/`#sync`'s extra hardcoded `admin_only!`; any controller with no profile guard today (stock, products, PDV, etc.); business rules using `admin?`/`manager?` outside of screen access (e.g. `StockCorrectionsController`, `allowed_locations`).

---

## File Structure

**Create:**
- `db/migrate/20260913230000_create_screen_permissions.rb` — table + seed data in one migration (matches existing convention, see `db/migrate/20251030043847_convert_profile_to_multiple_profiles.rb`)
- `app/models/screen.rb` — the curated screen list
- `app/controllers/profiles_controller.rb` — CRUD for profiles + their screen access
- `app/views/profiles/index.html.erb`, `new.html.erb`, `edit.html.erb`, `_form.html.erb`
- `test/models/screen_test.rb`
- `test/models/profile_test.rb`
- `test/controllers/users_controller_test.rb` — proves `guard_screen` actually blocks/allows before rolling it out to 7 more controllers
- `test/controllers/profiles_controller_test.rb`

**Modify:**
- `app/models/profile.rb` — add `screen_permissions` association + `can_access?`/`screen_keys`/`screen_keys=`
- `app/models/user.rb` — add `can_access_screen?`, remove dead `can_access_feature?`
- `app/controllers/application_controller.rb` — add `self.guard_screen` + `authorize_screen!`
- `app/controllers/users_controller.rb`, `orders_controller.rb`, `customers_controller.rb`, `discounts_controller.rb`, `logs_controller.rb`, `dashboard_controller.rb`, `marketing_campaigns_controller.rb`, `marketing_tasks_controller.rb` — swap old guard for `guard_screen`
- `config/routes.rb` — add `resources :profiles`
- `app/views/layouts/partials/_sidebar.html.erb` — add "Perfis e Permissões" link
- `test/models/user_test.rb` — add `can_access_screen?` cases
- `test/test_helper.rb` — add `Devise::Test::IntegrationHelpers` (needed by the new controller tests; no controller test currently exists in this app)

---

### Screen → controller → seed mapping (source of truth, copy exactly)

| `screen_key` | Controller | Guard replaced | Seeded profile IDs |
|---|---|---|---|
| `users_management` | `UsersController` | `admin_required` (except `edit`/`update`) | `1` |
| `orders` | `OrdersController` | `require_admin!` | `1`, `5`, `6` |
| `customers` | `CustomersController` | `require_admin!` | `1`, `5`, `6` |
| `discounts` | `DiscountsController` | `admin_or_manager!` | `1`, `2` |
| `logs` | `LogsController` | `admin_only!` | `1` |
| `dashboard_correios` | `DashboardController` | `admin_only!` | `1` |
| `marketing_campaigns` | `MarketingCampaignsController` | `check_admin_marketing_access` | `1`, `5` |
| `marketing_tasks` | `MarketingTasksController` | `check_marketing_access` | `1`, `5`, `6` |

(Profile IDs: `1` = Admin, `2` = Gerente, `3` = Usuário, `5` = Admin Marketing, `6` = Agente Marketing — from `Profile::ADMIN`/`MANAGER`/`USER`/`ADMIN_MARKETING`/`AGENT_MARKETING`.)

---

### Task 1: `screen_permissions` table, seed data, and `Screen` constant

**Files:**
- Create: `db/migrate/20260913230000_create_screen_permissions.rb`
- Create: `app/models/screen.rb`
- Test: `test/models/screen_test.rb`

**Interfaces:**
- Produces: `Screen.keys` (`Array<String>`), `Screen.options_for_select` (`Array<[String, String]>`), `Screen.label(key)` (`String | nil`); table `screen_permissions(profile_id, screen_key, created_at, updated_at)` unique on `[profile_id, screen_key]`.

- [ ] **Step 1: Write the migration**

```ruby
# db/migrate/20260913230000_create_screen_permissions.rb
class CreateScreenPermissions < ActiveRecord::Migration[7.2]
  def up
    create_table :screen_permissions do |t|
      t.references :profile, null: false, foreign_key: true
      t.string :screen_key, null: false
      t.timestamps
    end
    add_index :screen_permissions, [:profile_id, :screen_key], unique: true

    # Seed today's real access so no profile loses a screen on deploy.
    # 1=Admin, 2=Gerente, 3=Usuário, 5=Admin Marketing, 6=Agente Marketing
    execute <<-SQL
      INSERT INTO screen_permissions (profile_id, screen_key, created_at, updated_at) VALUES
        (1, 'users_management', NOW(), NOW()),
        (1, 'orders', NOW(), NOW()),
        (5, 'orders', NOW(), NOW()),
        (6, 'orders', NOW(), NOW()),
        (1, 'customers', NOW(), NOW()),
        (5, 'customers', NOW(), NOW()),
        (6, 'customers', NOW(), NOW()),
        (1, 'discounts', NOW(), NOW()),
        (2, 'discounts', NOW(), NOW()),
        (1, 'logs', NOW(), NOW()),
        (1, 'dashboard_correios', NOW(), NOW()),
        (1, 'marketing_campaigns', NOW(), NOW()),
        (5, 'marketing_campaigns', NOW(), NOW()),
        (1, 'marketing_tasks', NOW(), NOW()),
        (5, 'marketing_tasks', NOW(), NOW()),
        (6, 'marketing_tasks', NOW(), NOW())
    SQL
  end

  def down
    drop_table :screen_permissions
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `bin/rails db:migrate`
Expected: `== 20260913230000 CreateScreenPermissions: migrated` with no errors, and `db/schema.rb` now has a `screen_permissions` table with version `2026_09_13_230000`.

- [ ] **Step 3: Write the `Screen` model**

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
    marketing_tasks:     'Tarefas de Marketing'
  }.freeze

  def self.keys = DEFINITIONS.keys.map(&:to_s)
  def self.options_for_select = DEFINITIONS.map { |k, v| [v, k.to_s] }
  def self.label(key) = DEFINITIONS[key.to_sym]
end
```

- [ ] **Step 4: Write the failing test**

```ruby
# test/models/screen_test.rb
require 'test_helper'

class ScreenTest < ActiveSupport::TestCase
  test 'keys returns all screen keys as strings' do
    assert_includes Screen.keys, 'users_management'
    assert_includes Screen.keys, 'marketing_tasks'
    assert_equal 8, Screen.keys.size
  end

  test 'label returns the business name for a known key' do
    assert_equal 'Gerenciar Usuários', Screen.label(:users_management)
    assert_equal 'Gerenciar Usuários', Screen.label('users_management')
  end

  test 'label returns nil for an unknown key' do
    assert_nil Screen.label(:not_a_real_screen)
  end

  test 'options_for_select pairs label with key' do
    assert_includes Screen.options_for_select, ['Pedidos', 'orders']
  end
end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bin/rails test test/models/screen_test.rb`
Expected: PASS (4 runs, 0 failures)

- [ ] **Step 6: Commit**

```bash
git add db/migrate/20260913230000_create_screen_permissions.rb db/schema.rb app/models/screen.rb test/models/screen_test.rb
git commit -m "feat: add screen_permissions table and Screen constant with seed data"
```

---

### Task 2: `Profile` model — screen access

**Files:**
- Modify: `app/models/profile.rb`
- Test: `test/models/profile_test.rb`

**Interfaces:**
- Consumes: `Screen.keys` (Task 1).
- Produces: `Profile#can_access?(screen_key)` (`Boolean`), `Profile#screen_keys` (`Array<String>`), `Profile#screen_keys=(keys)` (writer, replaces the whole set).

- [ ] **Step 1: Write the failing tests**

```ruby
# test/models/profile_test.rb
require 'test_helper'

class ProfileTest < ActiveSupport::TestCase
  def setup
    @profile = Profile.create!(name: 'Perfil de Teste')
  end

  test 'can_access? is false with no permissions' do
    refute @profile.can_access?('orders')
  end

  test 'can_access? is true once the screen is granted' do
    @profile.screen_permissions.create!(screen_key: 'orders')
    assert @profile.can_access?('orders')
    assert @profile.can_access?(:orders)
  end

  test 'screen_keys= replaces the whole permission set' do
    @profile.screen_keys = %w[orders customers]
    @profile.save!
    assert_equal %w[customers orders], @profile.reload.screen_keys.sort

    @profile.screen_keys = ['orders']
    @profile.save!
    assert_equal ['orders'], @profile.reload.screen_keys
  end

  test 'screen_keys= ignores blank and unknown keys' do
    @profile.screen_keys = ['orders', '', nil, 'not_a_real_screen']
    @profile.save!
    assert_equal ['orders'], @profile.reload.screen_keys
  end

  test 'destroying a profile destroys its screen_permissions' do
    @profile.screen_permissions.create!(screen_key: 'orders')
    permission_id = @profile.screen_permissions.first.id
    @profile.destroy
    assert_nil ScreenPermission.find_by(id: permission_id)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/models/profile_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'can_access?' for #<Profile>` (and similar for the others).

- [ ] **Step 3: Implement in `Profile`**

Modify `app/models/profile.rb` — add the association and methods right after the existing `has_many :users, through: :user_profiles` line:

```ruby
class Profile < ApplicationRecord
  has_many :user_profiles, dependent: :destroy
  has_many :users, through: :user_profiles
  has_many :screen_permissions, dependent: :destroy

  validates :name, presence: true

  ADMIN = 1
  MANAGER = 2
  USER = 3
  ADMIN_MARKETING = 5
  AGENT_MARKETING = 6

  def marketing_profile?
    [ADMIN_MARKETING, AGENT_MARKETING].include?(id)
  end

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
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/models/profile_test.rb`
Expected: PASS (5 runs, 0 failures)

- [ ] **Step 5: Commit**

```bash
git add app/models/profile.rb test/models/profile_test.rb
git commit -m "feat: add screen access methods to Profile"
```

---

### Task 3: `User` model — `can_access_screen?`

**Files:**
- Modify: `app/models/user.rb`
- Test: `test/models/user_test.rb`

**Interfaces:**
- Consumes: `Profile#can_access?` (Task 2).
- Produces: `User#can_access_screen?(screen_key)` (`Boolean`).

- [ ] **Step 1: Write the failing tests**

Replace the whole content of `test/models/user_test.rb` (currently an empty stub):

```ruby
# test/models/user_test.rb
require 'test_helper'

class UserTest < ActiveSupport::TestCase
  test 'admin can access any screen regardless of profile permissions' do
    admin = User.new(name: 'Admin', email: 'admin@example.com', password: 'password123')
    admin.profiles << Profile.find(Profile::ADMIN)
    assert admin.can_access_screen?('marketing_tasks')
  end

  test 'non-admin can access a screen only if one of their profiles grants it' do
    profile = Profile.create!(name: 'Perfil Sem Acesso')
    user = User.new(name: 'Teste', email: 'teste@example.com', password: 'password123')
    user.profiles << profile
    refute user.can_access_screen?('orders')

    profile.screen_permissions.create!(screen_key: 'orders')
    assert user.can_access_screen?('orders')
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/models/user_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'can_access_screen?' for #<User>`

- [ ] **Step 3: Implement in `User`, remove dead code**

Modify `app/models/user.rb` — add `can_access_screen?` next to the other `can_access_*` method, and delete `can_access_feature?` entirely (confirmed unused anywhere in `app/` or `test/`):

```ruby
  def can_access_screen?(screen_key)
    admin? || profiles.any? { |p| p.can_access?(screen_key.to_s) }
  end
```

Remove this whole method (dead code, replaced by the screen system):

```ruby
  def can_access_feature?(feature)
    permissions = {
      user_management: -> { admin? },
      location_management: -> { admin? },
      stock_corrections: -> { location_access? },
      inventory_control: -> { location_access? },
      reports: -> { admin? || manager? },
      marketing_campaigns_admin: -> { admin? || admin_marketing? },
      marketing_tasks: -> { admin? || marketing_user? },
      marketing_dashboard: -> { admin? || marketing_user? }
    }

    permissions[feature]&.call || false
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/models/user_test.rb`
Expected: PASS (2 runs, 0 failures)

- [ ] **Step 5: Commit**

```bash
git add app/models/user.rb test/models/user_test.rb
git commit -m "feat: add User#can_access_screen?, remove dead can_access_feature?"
```

---

### Task 4: `guard_screen` + migrate all 8 controllers

**Files:**
- Modify: `app/controllers/application_controller.rb`
- Modify: `app/controllers/users_controller.rb`
- Modify: `app/controllers/orders_controller.rb`
- Modify: `app/controllers/customers_controller.rb`
- Modify: `app/controllers/discounts_controller.rb`
- Modify: `app/controllers/logs_controller.rb`
- Modify: `app/controllers/dashboard_controller.rb`
- Modify: `app/controllers/marketing_campaigns_controller.rb`
- Modify: `app/controllers/marketing_tasks_controller.rb`
- Test: `test/controllers/users_controller_test.rb`
- Modify: `test/test_helper.rb`

**Interfaces:**
- Consumes: `User#can_access_screen?` (Task 3).
- Produces: `ApplicationController.guard_screen(key, **options)` (class method, installs a `before_action`).

This task is mechanical for 7 of the 8 controllers. We write one real test against `UsersController` (the simplest guard: `except: [:edit, :update]`) to prove `guard_screen`/`authorize_screen!` actually work end-to-end, since this app has no controller test today. The other 7 controllers get the identical, already-proven pattern applied without a new test file each — there is nothing controller-specific to prove twice.

- [ ] **Step 1: Add `Devise::Test::IntegrationHelpers`**

Modify `test/test_helper.rb`:

```ruby
ENV['RAILS_ENV'] ||= 'test'
require_relative '../config/environment'
require 'rails/test_help'

class ActiveSupport::TestCase
  # Run tests in parallel with specified workers
  parallelize(workers: :number_of_processors)

  # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
  fixtures :all

  # Add more helper methods to be used by all tests here...
end

class ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
end
```

- [ ] **Step 2: Write the failing test for `UsersController`**

```ruby
# test/controllers/users_controller_test.rb
require 'test_helper'

class UsersControllerTest < ActionDispatch::IntegrationTest
  test 'admin can access the users index' do
    admin = User.create!(name: 'Admin', email: 'admin@example.com', password: 'password123')
    admin.profiles << Profile.find(Profile::ADMIN)
    sign_in admin

    get users_path
    assert_response :success
  end

  test 'a user whose profile has no users_management access is redirected' do
    profile = Profile.create!(name: 'Sem Acesso')
    user = User.create!(name: 'Sem Acesso', email: 'sem_acesso@example.com', password: 'password123')
    user.profiles << profile
    sign_in user

    get users_path
    assert_redirected_to root_path
  end

  test 'a non-admin can still edit their own record' do
    profile = Profile.create!(name: 'Sem Acesso 2')
    user = User.create!(name: 'Auto Edicao', email: 'auto_edicao@example.com', password: 'password123')
    user.profiles << profile
    sign_in user

    get edit_user_path(user)
    assert_response :success
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bin/rails test test/controllers/users_controller_test.rb`
Expected: FAIL on the "no access is redirected" case — today's `admin_required` doesn't know about screens, so behavior around `users_management` doesn't exist yet as a concept (the test as-is may currently pass by coincidence via `admin_required`; re-run after Step 4 and confirm all three pass through `guard_screen`, not the old method).

- [ ] **Step 4: Add `guard_screen` to `ApplicationController`**

Modify `app/controllers/application_controller.rb`:

```ruby
class ApplicationController < ActionController::Base
  include Common

  before_action :authenticate_user!
  protect_from_forgery unless: -> { request.format.json? }

  layout 'layouts/application'

  def self.guard_screen(key, **options)
    before_action(**options) { authorize_screen!(key) }
  end

  private

  def admin_only!
    redirect_to root_path, alert: 'Acesso negado. Apenas administradores podem acessar esta funcionalidade.' unless current_user&.admin?
  end

  def admin_or_manager!
    redirect_to root_path, alert: 'Acesso negado.' unless current_user&.admin? || current_user&.manager?
  end

  def authorize_screen!(screen_key)
    return if current_user&.can_access_screen?(screen_key)
    redirect_to root_path, alert: 'Acesso negado.'
  end
end
```

- [ ] **Step 5: Migrate `UsersController`**

In `app/controllers/users_controller.rb`, replace:

```ruby
  before_action :admin_required, except: [:edit, :update]
```
with:
```ruby
  guard_screen :users_management, except: [:edit, :update]
```

And delete the now-unused private method:

```ruby
  def admin_required
    unless current_user.admin?
      redirect_to root_path, alert: 'Acesso negado.'
    end
  end
```

- [ ] **Step 6: Run test to verify it passes**

Run: `bin/rails test test/controllers/users_controller_test.rb`
Expected: PASS (3 runs, 0 failures)

- [ ] **Step 7: Migrate the remaining 7 controllers (same pattern, no guard behavior change beyond the mapping table)**

`app/controllers/orders_controller.rb` — replace:
```ruby
  before_action :require_admin!
```
with:
```ruby
  guard_screen :orders
```
Delete:
```ruby
  def require_admin!
    redirect_to root_path, alert: "Acesso restrito a administradores." unless current_user&.admin? || current_user&.profiles&.any?(&:marketing_profile?)
  end
```

`app/controllers/customers_controller.rb` — replace:
```ruby
  before_action :require_admin!
```
with:
```ruby
  guard_screen :customers
```
Delete:
```ruby
  def require_admin!
    unless current_user&.admin? || current_user&.profiles&.any?(&:marketing_profile?)
      redirect_to root_path, alert: "Acesso restrito a administradores."
    end
  end
```

`app/controllers/discounts_controller.rb` — replace:
```ruby
  before_action :admin_or_manager!, except: []
  before_action :admin_only!, only: [:logs, :sync]
```
with:
```ruby
  guard_screen :discounts
  before_action :admin_only!, only: [:logs, :sync]
```
(the second line is untouched — out of scope, per Global Constraints). Delete only the now-unused private method:
```ruby
  def admin_or_manager!
    return if current_user&.admin? || current_user&.manager?

    redirect_to root_path, alert: 'Acesso negado.'
  end
```
Keep `def admin_only!` in this controller as-is (still used by `:logs`/`:sync`).

`app/controllers/logs_controller.rb` — replace:
```ruby
  before_action :admin_only!
```
with:
```ruby
  guard_screen :logs
```
Delete:
```ruby
  def admin_only!
    return if current_user&.admin?
    redirect_to root_path, alert: 'Acesso negado. Apenas administradores podem acessar esta funcionalidade.'
  end
```

`app/controllers/dashboard_controller.rb` — replace:
```ruby
  before_action :admin_only!
```
with:
```ruby
  guard_screen :dashboard_correios
```
Delete:
```ruby
  def admin_only!
    unless current_user&.admin?
      redirect_to dashboard_index_path, alert: 'Acesso negado. Apenas administradores podem acessar esta funcionalidade.'
    end
  end
```

`app/controllers/marketing_campaigns_controller.rb` — replace:
```ruby
  before_action :check_admin_marketing_access
```
with:
```ruby
  guard_screen :marketing_campaigns
```
Delete:
```ruby
  def check_admin_marketing_access
    unless current_user.admin? || current_user.admin_marketing?
      redirect_to root_path, alert: 'Acesso negado!'
    end
  end
```

`app/controllers/marketing_tasks_controller.rb` — replace:
```ruby
  before_action :check_marketing_access
```
with:
```ruby
  guard_screen :marketing_tasks
```
(leave `before_action :redirect_agent_from_dashboard, only: [:index, :dashboard]` untouched — unrelated business rule, not a screen guard). Delete:
```ruby
  def check_marketing_access
    unless current_user.admin? || current_user.agent_marketing? || current_user.admin_marketing?
      redirect_to root_path, alert: 'Acesso negado!'
    end
  end
```

- [ ] **Step 8: Run the full test suite**

Run: `bin/rails test`
Expected: all tests pass, no errors from the 7 mechanically-migrated controllers failing to boot (a typo in a `before_action` line would raise `NoMethodError` immediately on any request to that controller — there is no dedicated test for them, so also smoke-check with Step 9).

- [ ] **Step 9: Manual smoke check**

Run: `bin/rails runner "puts OrdersController.new.respond_to?(:authorize_screen!, true)"` for each of the 7 mechanically-edited controllers (swap the class name), or simply start the server (`bin/rails server`) and load `/orders`, `/customers`, `/discounts`, `/logs`, `/dashboard`, `/marketing_campaigns`, `/marketing_tasks` as an admin user — each must load normally (the seed data from Task 1 already grants Admin every screen).

- [ ] **Step 10: Commit**

```bash
git add app/controllers/application_controller.rb app/controllers/users_controller.rb app/controllers/orders_controller.rb app/controllers/customers_controller.rb app/controllers/discounts_controller.rb app/controllers/logs_controller.rb app/controllers/dashboard_controller.rb app/controllers/marketing_campaigns_controller.rb app/controllers/marketing_tasks_controller.rb test/controllers/users_controller_test.rb test/test_helper.rb
git commit -m "feat: migrate all profile guards to the screen permission system"
```

---

### Task 5: `ProfilesController` — CRUD for profiles and their screens

**Files:**
- Create: `app/controllers/profiles_controller.rb`
- Create: `app/views/profiles/index.html.erb`
- Create: `app/views/profiles/new.html.erb`
- Create: `app/views/profiles/edit.html.erb`
- Create: `app/views/profiles/_form.html.erb`
- Modify: `config/routes.rb`
- Test: `test/controllers/profiles_controller_test.rb`

**Interfaces:**
- Consumes: `Screen.options_for_select` (Task 1), `Profile#screen_keys=`/`#screen_keys` (Task 2), `ApplicationController#admin_only!` (already exists), `Devise::Test::IntegrationHelpers` (Task 4).
- Produces: routes `profiles_path`, `new_profile_path`, `edit_profile_path(profile)`.

- [ ] **Step 1: Add the route**

Modify `config/routes.rb` — add right before `resources :users do`:

```ruby
  resources :profiles

  resources :users do
```

- [ ] **Step 2: Write the failing controller tests**

```ruby
# test/controllers/profiles_controller_test.rb
require 'test_helper'

class ProfilesControllerTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(name: 'Admin', email: 'admin_profiles@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
  end

  test 'non-admin is redirected away from the index' do
    profile = Profile.create!(name: 'Perfil Comum')
    user = User.create!(name: 'Comum', email: 'comum@example.com', password: 'password123')
    user.profiles << profile
    sign_in user

    get profiles_path
    assert_redirected_to root_path
  end

  test 'admin can list, create, update and see the screen checkboxes' do
    sign_in @admin

    get profiles_path
    assert_response :success

    get new_profile_path
    assert_response :success

    assert_difference 'Profile.count', 1 do
      post profiles_path, params: { profile: { name: 'Financeiro', description: 'Time financeiro', active: true, screen_keys: ['orders', 'customers'] } }
    end
    profile = Profile.find_by(name: 'Financeiro')
    assert_redirected_to profiles_path
    assert_equal %w[customers orders], profile.screen_keys.sort

    patch profile_path(profile), params: { profile: { screen_keys: ['orders'] } }
    assert_equal ['orders'], profile.reload.screen_keys
  end

  test 'destroy is blocked when the profile still has users' do
    sign_in @admin

    profile_with_user = Profile.create!(name: 'Com Usuario')
    other_user = User.create!(name: 'Outro', email: 'outro@example.com', password: 'password123')
    other_user.profiles << profile_with_user

    assert_no_difference 'Profile.count' do
      delete profile_path(profile_with_user)
    end
    assert_redirected_to profiles_path
  end

  test 'destroy works when the profile has no users' do
    sign_in @admin
    empty_profile = Profile.create!(name: 'Vazio')

    assert_difference 'Profile.count', -1 do
      delete profile_path(empty_profile)
    end
  end
end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bin/rails test test/controllers/profiles_controller_test.rb`
Expected: FAIL — `ActionController::RoutingError` / uninitialized constant `ProfilesController`.

- [ ] **Step 4: Write `ProfilesController`**

```ruby
# app/controllers/profiles_controller.rb
class ProfilesController < ApplicationController
  before_action :admin_only!
  before_action :set_profile, only: [:edit, :update, :destroy]

  def index
    @profiles = Profile.left_joins(:users).select('profiles.*, COUNT(DISTINCT users.id) AS users_count').group('profiles.id').order(:name)
  end

  def new
    @profile = Profile.new
  end

  def create
    @profile = Profile.new(profile_params)
    if @profile.save
      redirect_to profiles_path, notice: 'Perfil criado com sucesso.'
    else
      render :new
    end
  end

  def edit; end

  def update
    if @profile.update(profile_params)
      redirect_to profiles_path, notice: 'Perfil atualizado com sucesso.'
    else
      render :edit
    end
  end

  def destroy
    if @profile.users.any?
      redirect_to profiles_path, alert: 'Não é possível excluir um perfil com usuários vinculados.'
      return
    end

    @profile.destroy
    redirect_to profiles_path, notice: 'Perfil removido com sucesso.'
  end

  private

  def set_profile
    @profile = Profile.find(params[:id])
  end

  def profile_params
    params.require(:profile).permit(:name, :description, :active, screen_keys: [])
  end
end
```

- [ ] **Step 5: Write the views**

```erb
<%# app/views/profiles/index.html.erb %>
<% content_for :title, "Perfis e Permissões" %>

<div class="users-container">
  <div class="page-header">
    <div class="header-left">
      <h1 class="page-title">
        <i class="fas fa-user-shield me-2"></i>Perfis e Permissões
      </h1>
      <p class="page-subtitle">Controle quais telas cada perfil pode acessar</p>
    </div>
    <div class="header-actions">
      <span class="total-badge">
        <i class="fas fa-list me-1"></i><%= @profiles.size %> perfil(is)
      </span>
      <%= link_to new_profile_path, class: "btn-export" do %>
        <i class="fas fa-plus me-2"></i>Novo Perfil
      <% end %>
    </div>
  </div>

  <div class="table-card">
    <div class="table-card-header">
      <h5 class="table-card-title">
        <i class="fas fa-list me-2"></i>Lista de Perfis
      </h5>
    </div>

    <% if @profiles.any? %>
      <div class="table-responsive">
        <table class="orders-table">
          <thead>
            <tr>
              <th>Nome</th>
              <th>Descrição</th>
              <th class="text-center">Status</th>
              <th class="text-center">Usuários</th>
              <th>Telas Permitidas</th>
              <th class="text-end">Ações</th>
            </tr>
          </thead>
          <tbody>
            <% @profiles.each do |profile| %>
              <tr>
                <td class="text-main"><%= profile.name %></td>
                <td class="text-muted-custom"><%= profile.description.presence || '-' %></td>
                <td class="text-center">
                  <span class="status-pill <%= profile.active? ? 'status-pill--active' : 'status-pill--inactive' %>">
                    <%= profile.active? ? 'Ativo' : 'Inativo' %>
                  </span>
                </td>
                <td class="text-center"><%= profile.users_count %></td>
                <td>
                  <% if profile.screen_keys.any? %>
                    <div class="location-chip-group">
                      <% profile.screen_keys.first(3).each do |key| %>
                        <span class="location-chip"><%= Screen.label(key) %></span>
                      <% end %>
                      <% if profile.screen_keys.count > 3 %>
                        <span class="location-chip location-chip--more">+<%= profile.screen_keys.count - 3 %></span>
                      <% end %>
                    </div>
                  <% else %>
                    <span class="text-muted-custom">Nenhuma</span>
                  <% end %>
                </td>
                <td class="text-end">
                  <div class="table-actions">
                    <%= link_to edit_profile_path(profile), class: "action-btn action-btn--edit" do %>
                      <i class="fas fa-pencil-alt"></i>
                    <% end %>
                    <%= link_to profile, method: :delete,
                                class: "action-btn action-btn--danger",
                                data: { confirm: "Tem certeza que deseja excluir este perfil?" } do %>
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
        <i class="fas fa-user-shield fa-3x mb-3 d-block"></i>
        <h5>Nenhum perfil encontrado</h5>
        <%= link_to new_profile_path, class: "btn-export" do %>
          <i class="fas fa-plus me-1"></i>Novo Perfil
        <% end %>
      </div>
    <% end %>
  </div>
</div>
```

```erb
<%# app/views/profiles/new.html.erb %>
<% content_for :title, "Novo Perfil" %>

<div class="users-container">
  <div class="page-header">
    <div class="header-left">
      <h1 class="page-title"><i class="fas fa-user-shield me-2"></i>Novo Perfil</h1>
      <p class="page-subtitle">Crie um novo perfil e defina suas telas permitidas</p>
    </div>
    <div class="header-actions">
      <%= link_to profiles_path, class: "btn-back" do %>
        <i class="fas fa-arrow-left me-1"></i>Voltar
      <% end %>
    </div>
  </div>

  <%= render 'form' %>
</div>
```

```erb
<%# app/views/profiles/edit.html.erb %>
<% content_for :title, "Editar Perfil" %>

<div class="users-container">
  <div class="page-header">
    <div class="header-left">
      <h1 class="page-title"><i class="fas fa-user-shield me-2"></i>Editar Perfil</h1>
      <p class="page-subtitle"><%= @profile.name %></p>
    </div>
    <div class="header-actions">
      <%= link_to profiles_path, class: "btn-back" do %>
        <i class="fas fa-arrow-left me-1"></i>Voltar
      <% end %>
    </div>
  </div>

  <%= render 'form' %>
</div>
```

```erb
<%# app/views/profiles/_form.html.erb %>
<%= form_with model: @profile, local: true, class: 'needs-validation', novalidate: true do |form| %>
  <% if @profile.errors.any? %>
    <div class="form-error-box">
      <i class="fas fa-exclamation-triangle me-2"></i>
      <ul class="mb-0 mt-1">
        <% @profile.errors.full_messages.each do |message| %>
          <li><%= message %></li>
        <% end %>
      </ul>
    </div>
  <% end %>

  <div class="form-section">
    <div class="form-section-header">
      <h5 class="form-section-title"><i class="fas fa-id-badge me-2"></i>Informações Básicas</h5>
    </div>
    <div class="form-section-body">
      <div class="form-grid">
        <div class="form-col-6">
          <label class="field-label">Nome <span class="required">*</span></label>
          <%= form.text_field :name,
              class: "field-input #{'field-input--error' if @profile.errors[:name].any?}",
              required: true %>
          <% if @profile.errors[:name].any? %>
            <span class="field-error"><%= @profile.errors[:name].first %></span>
          <% end %>
        </div>
        <div class="form-col-6">
          <label class="field-label">Descrição</label>
          <%= form.text_field :description, class: "field-input" %>
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
        <%= form.check_box :active, class: 'form-check-input', role: 'switch', checked: @profile.new_record? ? true : @profile.active? %>
        <label class="form-check-label text-main fw-bold">Perfil Ativo</label>
      </div>
    </div>
  </div>

  <div class="form-section">
    <div class="form-section-header">
      <h5 class="form-section-title"><i class="fas fa-desktop me-2"></i>Telas Permitidas</h5>
    </div>
    <div class="form-section-body">
      <div class="form-grid">
        <% Screen.options_for_select.each do |label, key| %>
          <div class="form-col-4">
            <div class="form-check">
              <%= check_box_tag 'profile[screen_keys][]',
                                key,
                                @profile.screen_keys.include?(key),
                                { class: 'form-check-input', id: "screen_#{key}" } %>
              <label class="form-check-label text-main" for="screen_<%= key %>"><%= label %></label>
            </div>
          </div>
        <% end %>
      </div>
      <span class="text-muted-custom d-block mt-2">
        <i class="fas fa-info-circle me-1"></i>
        Perfis novos começam sem nenhuma tela marcada.
      </span>
    </div>
  </div>

  <div class="form-actions">
    <%= form.submit (@profile.new_record? ? 'Criar Perfil' : 'Salvar Alterações'), class: "btn-submit" %>
    <%= link_to "Cancelar", profiles_path, class: "btn-cancel" %>
  </div>
<% end %>
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bin/rails test test/controllers/profiles_controller_test.rb`
Expected: PASS (4 runs, 0 failures)

- [ ] **Step 7: Commit**

```bash
git add config/routes.rb app/controllers/profiles_controller.rb app/views/profiles test/controllers/profiles_controller_test.rb
git commit -m "feat: add ProfilesController CRUD for screen permissions"
```

---

### Task 6: Sidebar navigation link

**Files:**
- Modify: `app/views/layouts/partials/_sidebar.html.erb`
- Test: `test/controllers/profiles_controller_test.rb` (extend, no new file)

**Interfaces:**
- Consumes: `profiles_path` (Task 5), `current_user&.admin?` (existing).

- [ ] **Step 1: Write the failing test**

Add to `test/controllers/profiles_controller_test.rb`:

```ruby
  test 'the sidebar shows the profiles link only to admins' do
    sign_in @admin
    get root_path
    assert_select "a[href='#{profiles_path}']", text: /Perfis e Permissões/

    sign_out @admin
    profile = Profile.create!(name: 'Perfil Comum 2')
    user = User.create!(name: 'Comum 2', email: 'comum2@example.com', password: 'password123')
    user.profiles << profile
    sign_in user

    get root_path
    assert_select "a[href='#{profiles_path}']", count: 0
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/controllers/profiles_controller_test.rb`
Expected: FAIL — no such link in the sidebar yet.

- [ ] **Step 3: Add the link**

Modify `app/views/layouts/partials/_sidebar.html.erb` — in the "Usuários" dropdown, right after the existing "Gerenciar Usuários" link:

```erb
              <% if current_user&.admin? %>
                <%= link_to users_path, class: "dropdown-link #{'active' if controller_name == 'users'}" do %>
                  <i class="fas fa-users-cog"></i>
                  <span>Gerenciar Usuários</span>
                <% end %>
                <%= link_to profiles_path, class: "dropdown-link #{'active' if controller_name == 'profiles'}" do %>
                  <i class="fas fa-user-shield"></i>
                  <span>Perfis e Permissões</span>
                <% end %>
              <% end %>
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/controllers/profiles_controller_test.rb`
Expected: PASS (5 runs, 0 failures)

- [ ] **Step 5: Commit**

```bash
git add app/views/layouts/partials/_sidebar.html.erb test/controllers/profiles_controller_test.rb
git commit -m "feat: add Perfis e Permissões link to the sidebar for admins"
```

---

### Task 7: Full suite + manual verification

**Files:** none (verification only)

- [ ] **Step 1: Run the entire test suite**

Run: `bin/rails test`
Expected: 0 failures, 0 errors.

- [ ] **Step 2: Manual browser check**

Run: `bin/rails server`, log in as an existing Admin user, and verify:
- Sidebar → Usuários → "Perfis e Permissões" is visible and opens `/profiles`.
- Existing perfis (Admin, Gerente, Usuário, Admin Marketing, Agente Marketing) show the screens listed in the seed mapping table pre-checked.
- Creating a new perfil with no screens checked, then editing it to check "Pedidos", persists correctly.
- Log in as a non-admin user (e.g. a plain "Usuário" profile) and confirm the "Perfis e Permissões" link is absent, and `/profiles` redirects to root with "Acesso negado." if visited directly.
- Confirm a user whose only profile is "Gerente" can still reach `/discounts` (seeded) but not `/logs` (not seeded).

- [ ] **Step 3: Commit anything left uncommitted**

```bash
git status
```
Expected: clean (every task above already committed its own changes).
