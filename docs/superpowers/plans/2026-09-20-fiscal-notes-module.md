# Módulo de Notas Fiscais e Empresas Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cadastro de empresas emissoras (com certificado A1 no Bucketeer) e geração manual, por clique no pedido B2B, de NF-e modelo 55 assinada.

**Architecture:** Models `Company` e `FiscalNote` + serviços puros em `app/services/nfe/` (`Certificate`, `Cnpj`, `XmlBuilder`, `Signer`, `Generator`). Storage via Active Storage no serviço `bucketeer`. Nada existente chama o gerador; só a tela "Gerar nota fiscal".

**Tech Stack:** Rails 7.2, MySQL, Active Storage + `aws-sdk-s3` (já no Gemfile), `ActiveRecord::Encryption`, Nokogiri 1.18, OpenSSL (stdlib), Minitest + webmock.

**Spec:** `docs/superpowers/specs/2026-09-20-fiscal-notes-module-design.md`

## Global Constraints

- NF-e de produto, modelo 55, layout 4.00. Sem NFS-e.
- **Sem transmissão à SEFAZ**: nota nunca passa de `assinada`.
- CFOPs iniciais: venda 5102/6102, transferência 5152/6152 (dentro/fora da UF), editáveis por empresa.
- Uma nota ativa por pedido; nova geração só se a anterior estiver em `erro`, `rejeitada` ou `cancelada`.
- Certificado privado: nunca baixável; senha com `encrypts`, em `filter_parameters`, nunca renderizada.
- Certificado com CNPJ diferente do da empresa, vencido, ou com senha errada é recusado.
- Número da NF-e só é consumido se a geração inteira der certo (transação).
- Variáveis Bucketeer: `BUCKETEER_AWS_ACCESS_KEY_ID`, `BUCKETEER_AWS_SECRET_ACCESS_KEY`, `BUCKETEER_BUCKET_NAME`, `BUCKETEER_AWS_REGION`.
- Menu: grupo "Pedidos" vira "Pedidos B2B"; novas telas `companies` e `fiscal_notes`.
- **Regras do usuário:** nunca rodar `git commit` sem pedido explícito (por isso não há passos de commit); nunca rodar `db:migrate` no banco de dev (é o banco compartilhado com produção) — migrations são aplicadas só no MySQL temporário de teste e o usuário aplica no dev/prod.
- Mensagens ao usuário em português.

## Ambiente de teste (usado em todas as tasks)

O MySQL do Homebrew está quebrado; usar um `mysql@8.0` temporário:

```bash
S=<scratchpad>; M=/opt/homebrew/opt/mysql@8.0/bin
($M/mysqld --datadir=$S/mydata --socket=/tmp/chase_my.sock --port=3390 --bind-address=127.0.0.1 --mysqlx=OFF > $S/mysqld.log 2>&1 &); sleep 12
export TEST_DATABASE_URL="mysql2://root@127.0.0.1:3390/chase_test" PARALLEL_WORKERS=1
```

O banco temporário tem `profiles` seedados (ids 1,2,3,5,6). Os fixtures do projeto violam índices únicos; por isso os índices únicos foram removidos **só nesse banco**. Ao aplicar migrations novas nele: `RAILS_ENV=test bin/rails db:migrate` (atualiza `db/schema.rb` — conferir depois que o diff do schema contém só as tabelas/colunas novas, sem os índices únicos removidos: se contaminar, recriar o banco com `db:schema:load` a partir do schema antes de migrar).

## File Structure

| Arquivo | Responsabilidade |
|---|---|
| `config/storage.yml`, `config/environments/{development,production}.rb` | serviço `bucketeer` |
| `config/application.rb`, `config/environments/test.rb`, `config/initializers/filter_parameter_logging.rb` | chaves de criptografia e filtro de senha |
| `app/models/screen.rb`, `app/views/layouts/partials/_sidebar.html.erb` | menu e permissões |
| `app/services/nfe/cnpj.rb` | validação/formatação de CNPJ |
| `app/services/nfe/certificate.rb` | abre PKCS#12, expõe validade/CNPJ/chave |
| `app/models/company.rb`, `app/controllers/companies_controller.rb`, `app/views/companies/*` | cadastro de empresa |
| `db/migrate/*` | active storage, companies, colunas fiscais, fiscal_notes |
| `app/models/fiscal_note.rb`, `app/controllers/fiscal_notes_controller.rb`, `app/views/fiscal_notes/*` | notas: lista, detalhe, gerar, XML |
| `app/services/nfe/xml_builder.rb` | monta XML e chave |
| `app/services/nfe/signer.rb` | assina XML |
| `app/services/nfe/generator.rb` | orquestra a geração |
| `test/support/nfe_test_certificate.rb` | gera certificado A1 de teste |

---

### Task 1: Storage Bucketeer e criptografia

**Files:**
- Modify: `config/storage.yml`, `config/environments/development.rb:67`, `config/environments/production.rb:41`, `config/application.rb`, `config/environments/test.rb`, `config/initializers/filter_parameter_logging.rb`
- Create: `db/migrate/<ts>_create_active_storage_tables.active_storage.rb` (via `bin/rails active_storage:install`)
- Test: `test/config/storage_config_test.rb`

**Interfaces:**
- Produces: serviço Active Storage `:bucketeer`; `ActiveRecord::Encryption` configurado (para `encrypts`); tabelas `active_storage_*`.

- [ ] **Step 1: Teste (falha)**

```ruby
# test/config/storage_config_test.rb
require 'test_helper'

class StorageConfigTest < ActiveSupport::TestCase
  test 'bucketeer service reads the BUCKETEER_* variables and is private' do
    yml = ERB.new(Rails.root.join('config/storage.yml').read).result
    config = YAML.safe_load(yml, aliases: true)['bucketeer']

    assert_equal 'S3', config['service']
    assert_equal ENV['BUCKETEER_BUCKET_NAME'].to_s, config['bucket'].to_s
    assert_equal ENV['BUCKETEER_AWS_REGION'].to_s, config['region'].to_s
    assert_equal ENV['BUCKETEER_AWS_ACCESS_KEY_ID'].to_s, config['access_key_id'].to_s
    assert_equal false, config['public']
  end

  test 'development and production use the bucketeer service' do
    %w[development production].each do |env|
      assert_match(/active_storage\.service\s*=\s*:bucketeer/, Rails.root.join("config/environments/#{env}.rb").read)
    end
  end

  test 'attributes can be encrypted' do
    value = 'segredo'
    encrypted = ActiveRecord::Encryption.encryptor.encrypt(value)
    assert_not_equal value, encrypted
    assert_equal value, ActiveRecord::Encryption.encryptor.decrypt(encrypted)
  end

  test 'certificate_password is filtered from logs' do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    assert_equal '[FILTERED]', filter.filter(certificate_password: 'x')[:certificate_password]
  end
end
```

- [ ] **Step 2:** `bin/rails test test/config/storage_config_test.rb` → FAIL (serviço/criptografia ausentes).

- [ ] **Step 3: Implementação**

`config/storage.yml`: remover o serviço `amazon` e adicionar:

```yaml
bucketeer:
  service: S3
  access_key_id: <%= ENV['BUCKETEER_AWS_ACCESS_KEY_ID'] %>
  secret_access_key: <%= ENV['BUCKETEER_AWS_SECRET_ACCESS_KEY'] %>
  region: <%= ENV['BUCKETEER_AWS_REGION'] %>
  bucket: <%= ENV['BUCKETEER_BUCKET_NAME'] %>
  public: false
```

`config/environments/development.rb` e `production.rb`: `config.active_storage.service = :bucketeer`.

`config/application.rb` (dentro da classe `Application`):

```ruby
config.active_record.encryption.primary_key = ENV['ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY']
config.active_record.encryption.deterministic_key = ENV['ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY']
config.active_record.encryption.key_derivation_salt = ENV['ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT']
```

`config/environments/test.rb` (chaves fixas só para teste):

```ruby
config.active_record.encryption.primary_key = 'test-primary-key-0123456789abcdef'
config.active_record.encryption.deterministic_key = 'test-deterministic-key-0123456789ab'
config.active_record.encryption.key_derivation_salt = 'test-key-derivation-salt-0123456789'
```

`config/initializers/filter_parameter_logging.rb`: adicionar `:certificate_password` à lista.

Gerar migration: `bin/rails active_storage:install`. Gerar 3 chaves reais com `ruby -rsecurerandom -e 'puts SecureRandom.alphanumeric(32)'` (três vezes), anexar ao `.env` local como `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`, `..._DETERMINISTIC_KEY`, `..._KEY_DERIVATION_SALT` (conferir que `.env` está no `.gitignore`) e informar os valores ao usuário para cadastrar no Heroku. Os mesmos valores devem ser usados em dev e produção (mesmo banco).

- [ ] **Step 4:** `RAILS_ENV=test bin/rails db:migrate` no MySQL temporário e rodar o teste → PASS. Conferir `db/schema.rb` (só tabelas `active_storage_*` novas).

---

### Task 2: Menu "Pedidos B2B" e permissões

**Files:**
- Modify: `app/models/screen.rb`, `app/views/layouts/partials/_sidebar.html.erb:45-80`
- Test: `test/models/screen_test.rb` (existente — acrescentar), `test/controllers/flash_messages_test.rb` não muda

**Interfaces:**
- Produces: chaves `:companies` ("Empresas") e `:fiscal_notes` ("Notas Fiscais") em `Screen::DEFINITIONS`, no grupo `'Pedidos B2B'`; links `companies_path` e `fiscal_notes_path` no menu (rotas criadas na Task 5/7 — nesta task, adicionar as rotas mínimas `resources :companies` e `resources :fiscal_notes, only: [:index]` para o menu compilar; controllers vêm depois).

- [ ] **Step 1: Teste**

```ruby
test 'companies and fiscal_notes screens belong to the Pedidos B2B group' do
  assert_includes Screen::GROUPS['Pedidos B2B'], :companies
  assert_includes Screen::GROUPS['Pedidos B2B'], :fiscal_notes
  assert_equal 'Empresas', Screen::DEFINITIONS[:companies]
  assert_equal 'Notas Fiscais', Screen::DEFINITIONS[:fiscal_notes]
end
```

E, num teste de integração (arquivo novo `test/controllers/sidebar_test.rb`): logar admin, `get b2b_orders_path` e verificar `.nav-text` "Pedidos B2B" e links para `companies_path` e `fiscal_notes_path` (`assert_select "a[href='#{companies_path}']"`).

- [ ] **Step 2:** rodar → FAIL.
- [ ] **Step 3:** adicionar as chaves em `DEFINITIONS`, `%i[b2b_orders transfer_locations carriers companies fiscal_notes]` em `GROUPS`; no sidebar trocar `<span class="nav-text">Pedidos</span>` por `Pedidos B2B`, incluir `can_access_screen?('companies')` e `('fiscal_notes')` na condição do grupo e dois `link_to` (ícones `fa-building` e `fa-file-invoice`) seguindo o padrão dos links existentes; rotas mínimas em `config/routes.rb`.
- [ ] **Step 4:** rodar → PASS.

---

### Task 3: `Nfe::Cnpj` e `Nfe::Certificate`

**Files:**
- Create: `app/services/nfe/cnpj.rb`, `app/services/nfe/certificate.rb`, `test/support/nfe_test_certificate.rb`
- Test: `test/services/nfe/cnpj_test.rb`, `test/services/nfe/certificate_test.rb`

**Interfaces:**
- Produces:
  - `Nfe::Cnpj.digits(value) -> String`, `Nfe::Cnpj.valid?(value) -> Boolean`, `Nfe::Cnpj.format(value) -> String`.
  - `Nfe::Certificate.new(pfx_data, password)`; levanta `Nfe::Certificate::Error` (mensagem em pt-BR) com senha errada/arquivo inválido; `#certificate` (OpenSSL::X509::Certificate), `#private_key`, `#expires_at -> Time`, `#expired? -> Boolean`, `#subject -> String`, `#cnpj -> String|nil` (14 dígitos extraídos do CN), `#base64_der -> String`.
  - `NfeTestCertificate.pfx(cnpj: '11222333000181', password: 'senha123', not_after: 1.year.from_now) -> String` (DER PKCS#12 com CN `"EMPRESA TESTE LTDA:#{cnpj}"`).

- [ ] **Step 1: Testes**

```ruby
# test/support/nfe_test_certificate.rb
require 'openssl'

module NfeTestCertificate
  module_function

  def pfx(cnpj: '11222333000181', password: 'senha123', not_after: Time.now + 365 * 86_400)
    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = OpenSSL::X509::Name.parse("/C=BR/O=ICP-Brasil/CN=EMPRESA TESTE LTDA:#{cnpj}")
    cert.issuer = cert.subject
    cert.public_key = key.public_key
    cert.not_before = Time.now - 86_400
    cert.not_after = not_after
    cert.sign(key, OpenSSL::Digest.new('SHA256'))
    OpenSSL::PKCS12.create(password, 'teste', key, cert).to_der
  end
end
```

```ruby
# test/services/nfe/cnpj_test.rb
require 'test_helper'

class Nfe::CnpjTest < ActiveSupport::TestCase
  test 'accepts a valid CNPJ with or without mask' do
    assert Nfe::Cnpj.valid?('11.222.333/0001-81')
    assert Nfe::Cnpj.valid?('11222333000181')
  end

  test 'rejects wrong check digits, repeated digits and wrong length' do
    refute Nfe::Cnpj.valid?('11222333000182')
    refute Nfe::Cnpj.valid?('11111111111111')
    refute Nfe::Cnpj.valid?('123')
    refute Nfe::Cnpj.valid?(nil)
  end

  test 'formats and strips' do
    assert_equal '11.222.333/0001-81', Nfe::Cnpj.format('11222333000181')
    assert_equal '11222333000181', Nfe::Cnpj.digits('11.222.333/0001-81')
  end
end
```

```ruby
# test/services/nfe/certificate_test.rb
require 'test_helper'
require_relative '../../support/nfe_test_certificate'

class Nfe::CertificateTest < ActiveSupport::TestCase
  test 'reads validity, subject and CNPJ from a valid PKCS#12' do
    cert = Nfe::Certificate.new(NfeTestCertificate.pfx, 'senha123')

    assert_equal '11222333000181', cert.cnpj
    assert_match(/EMPRESA TESTE LTDA/, cert.subject)
    assert cert.expires_at > Time.now
    refute cert.expired?
    assert_kind_of OpenSSL::PKey::RSA, cert.private_key
    assert cert.base64_der.present?
  end

  test 'flags an expired certificate' do
    cert = Nfe::Certificate.new(NfeTestCertificate.pfx(not_after: Time.now - 60), 'senha123')
    assert cert.expired?
  end

  test 'raises a readable error with the wrong password' do
    error = assert_raises(Nfe::Certificate::Error) { Nfe::Certificate.new(NfeTestCertificate.pfx, 'errada') }
    assert_match(/senha/i, error.message)
  end

  test 'raises a readable error for a corrupted file' do
    assert_raises(Nfe::Certificate::Error) { Nfe::Certificate.new('lixo', 'senha123') }
  end
end
```

- [ ] **Step 2:** rodar → FAIL (`uninitialized constant Nfe`).
- [ ] **Step 3: Implementação**

```ruby
# app/services/nfe/cnpj.rb
module Nfe
  module Cnpj
    module_function

    def digits(value)
      value.to_s.gsub(/\D/, '')
    end

    def valid?(value)
      d = digits(value)
      return false unless d.length == 14 && d.chars.uniq.length > 1

      base = d[0, 12].chars.map(&:to_i)
      first = check_digit(base, [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2])
      second = check_digit(base + [first], [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2])
      d[12, 2] == "#{first}#{second}"
    end

    def format(value)
      digits(value).sub(/(\d{2})(\d{3})(\d{3})(\d{4})(\d{2})/, '\1.\2.\3/\4-\5')
    end

    def check_digit(numbers, weights)
      remainder = numbers.zip(weights).sum { |n, w| n * w } % 11
      remainder < 2 ? 0 : 11 - remainder
    end
    private_class_method :check_digit
  end
end
```

```ruby
# app/services/nfe/certificate.rb
require 'openssl'
require 'base64'

module Nfe
  class Certificate
    class Error < StandardError; end

    attr_reader :certificate, :private_key

    def initialize(pfx_data, password)
      pkcs12 = OpenSSL::PKCS12.new(pfx_data.to_s, password.to_s)
      @certificate = pkcs12.certificate
      @private_key = pkcs12.key
      raise Error, 'Certificado sem chave privada ou certificado.' unless @certificate && @private_key
    rescue OpenSSL::PKCS12::PKCS12Error, ArgumentError, TypeError
      raise Error, 'Senha do certificado inválida ou arquivo corrompido.'
    end

    def expires_at
      certificate.not_after
    end

    def expired?
      expires_at < Time.now
    end

    def subject
      certificate.subject.to_s
    end

    def cnpj
      common_name = certificate.subject.to_a.find { |name, _, _| name == 'CN' }&.[](1).to_s
      common_name[/\d{14}/]
    end

    def base64_der
      Base64.strict_encode64(certificate.to_der)
    end
  end
end
```

- [ ] **Step 4:** rodar → PASS.

---

### Task 4: Model `Company`

**Files:**
- Create: `db/migrate/<ts>_create_companies.rb`, `app/models/company.rb`
- Test: `test/models/company_test.rb`

**Interfaces:**
- Consumes: `Nfe::Cnpj`, `Nfe::Certificate` (Task 3), `NfeTestCertificate`.
- Produces: `Company` com colunas: `legal_name, trade_name, cnpj (14 dígitos), state_registration, municipal_registration, cnae, tax_regime (integer: 1,2,3), street, number, complement, neighbourhood, city, city_ibge_code, state, zip, phone, email, environment (integer enum: homologacao 2 / producao 1), nfe_series (integer, default 1), next_nfe_number (integer, default 1), cfop_sale_in_state ("5102"), cfop_sale_out_of_state ("6102"), cfop_transfer_in_state ("5152"), cfop_transfer_out_of_state ("6152"), operation_nature_sale ("Venda de mercadoria"), operation_nature_transfer ("Transferência de mercadoria"), icms_situation (string, default "102"), pis_cst ("49"), cofins_cst ("49"), active (boolean default true), certificate_password (encrypted), certificate_expires_at, certificate_subject, certificate_cnpj`. Virtual `certificate_file` (UploadedFile). `has_one_attached :certificate`. Métodos: `cnpj_formatted`, `certificate_status -> :missing|:expired|:expiring|:valid`, `nfe_certificate -> Nfe::Certificate` (do blob), `scope :active`, `scope :ready_to_issue` (ativas com certificado não vencido), `ready_to_issue? -> Boolean`, `state_code -> String (2 dígitos cUF)`, `has_many :fiscal_notes, dependent: :restrict_with_error` (declarar só na Task 7).

- [ ] **Step 1: Teste**

```ruby
require 'test_helper'
require_relative '../support/nfe_test_certificate'

class CompanyTest < ActiveSupport::TestCase
  def valid_attributes(overrides = {})
    { legal_name: 'Empresa Teste Ltda', cnpj: '11.222.333/0001-81', state_registration: '123456789',
      tax_regime: 1, street: 'Rua A', number: '10', neighbourhood: 'Centro', city: 'Belo Horizonte',
      city_ibge_code: '3106200', state: 'MG', zip: '30000-000' }.merge(overrides)
  end

  def upload(pfx)
    Rack::Test::UploadedFile.new(StringIO.new(pfx), 'application/x-pkcs12', original_filename: 'cert.pfx')
  end

  test 'is valid with the required fiscal data and normalizes the CNPJ to digits' do
    company = Company.new(valid_attributes)
    assert company.valid?, company.errors.full_messages.to_sentence
    assert_equal '11222333000181', company.cnpj
    assert_equal '11.222.333/0001-81', company.cnpj_formatted
  end

  test 'requires a valid and unique CNPJ' do
    refute Company.new(valid_attributes(cnpj: '11222333000182')).valid?
    Company.create!(valid_attributes)
    refute Company.new(valid_attributes).valid?
  end

  test 'requires a valid state and tax regime, and exposes the IBGE state code' do
    refute Company.new(valid_attributes(state: 'XX')).valid?
    refute Company.new(valid_attributes(tax_regime: 9)).valid?
    assert_equal '31', Company.new(valid_attributes).state_code
  end

  test 'has the default CFOPs and tax defaults' do
    company = Company.new
    assert_equal %w[5102 6102 5152 6152], [company.cfop_sale_in_state, company.cfop_sale_out_of_state, company.cfop_transfer_in_state, company.cfop_transfer_out_of_state]
    assert_equal 1, company.nfe_series
    assert_equal 1, company.next_nfe_number
    assert company.homologacao?
  end

  test 'accepts a certificate whose CNPJ matches and stores its metadata' do
    company = Company.new(valid_attributes(certificate_file: upload(NfeTestCertificate.pfx), certificate_password: 'senha123'))
    assert company.save, company.errors.full_messages.to_sentence
    assert company.certificate.attached?
    assert_equal '11222333000181', company.certificate_cnpj
    assert company.certificate_expires_at > Time.current
    assert_equal :valid, company.certificate_status
    assert company.ready_to_issue?
  end

  test 'rejects a certificate with the wrong password, other CNPJ or expired' do
    refute Company.new(valid_attributes(certificate_file: upload(NfeTestCertificate.pfx), certificate_password: 'errada')).valid?
    refute Company.new(valid_attributes(certificate_file: upload(NfeTestCertificate.pfx(cnpj: '45723174000110')), certificate_password: 'senha123')).valid?
    refute Company.new(valid_attributes(certificate_file: upload(NfeTestCertificate.pfx(not_after: Time.now - 60)), certificate_password: 'senha123')).valid?
  end

  test 'requires the password when a certificate is uploaded' do
    refute Company.new(valid_attributes(certificate_file: upload(NfeTestCertificate.pfx))).valid?
  end

  test 'certificate password is stored encrypted' do
    company = Company.create!(valid_attributes(certificate_file: upload(NfeTestCertificate.pfx), certificate_password: 'senha123'))
    raw = Company.connection.select_value("SELECT certificate_password FROM companies WHERE id = #{company.id}")
    assert_not_equal 'senha123', raw
    assert_equal 'senha123', company.reload.certificate_password
  end

  test 'certificate_status is missing without certificate and expiring within 30 days' do
    assert_equal :missing, Company.new(valid_attributes).certificate_status
    company = Company.new(valid_attributes(certificate_expires_at: 10.days.from_now))
    company.certificate.attach(io: StringIO.new('x'), filename: 'c.pfx')
    assert_equal :expiring, company.certificate_status
  end
end
```

- [ ] **Step 2:** rodar → FAIL.
- [ ] **Step 3: Implementação**

Migration `create_companies` (todas as colunas acima; `t.index :cnpj, unique: true`; defaults conforme Interfaces; `certificate_password` como `text`).

```ruby
# app/models/company.rb
class Company < ApplicationRecord
  STATES = { 'AC' => '12', 'AL' => '27', 'AP' => '16', 'AM' => '13', 'BA' => '29', 'CE' => '23', 'DF' => '53',
             'ES' => '32', 'GO' => '52', 'MA' => '21', 'MT' => '51', 'MS' => '50', 'MG' => '31', 'PA' => '15',
             'PB' => '25', 'PR' => '41', 'PE' => '26', 'PI' => '22', 'RJ' => '33', 'RN' => '24', 'RS' => '43',
             'RO' => '11', 'RR' => '14', 'SC' => '42', 'SP' => '35', 'SE' => '28', 'TO' => '17' }.freeze
  EXPIRING_DAYS = 30

  enum :environment, { producao: 1, homologacao: 2 }, default: :homologacao

  has_one_attached :certificate
  encrypts :certificate_password

  attr_accessor :certificate_file

  before_validation :normalize_cnpj
  validate :certificate_matches_company

  validates :legal_name, :street, :number, :neighbourhood, :city, :city_ibge_code, :zip, presence: true
  validates :cnpj, presence: true, uniqueness: true
  validates :state, inclusion: { in: STATES.keys }
  validates :tax_regime, inclusion: { in: [1, 2, 3] }
  validates :nfe_series, :next_nfe_number, numericality: { only_integer: true, greater_than: 0 }
  validates :cfop_sale_in_state, :cfop_sale_out_of_state, :cfop_transfer_in_state, :cfop_transfer_out_of_state,
            format: { with: /\A\d{4}\z/, message: 'deve ter 4 dígitos' }
  validate :cnpj_checksum

  scope :active, -> { where(active: true) }
  scope :ready_to_issue, -> { active.where('certificate_expires_at > ?', Time.current) }

  def cnpj_formatted
    Nfe::Cnpj.format(cnpj)
  end

  def state_code
    STATES[state]
  end

  def certificate_status
    return :missing unless certificate.attached? && certificate_expires_at
    return :expired if certificate_expires_at < Time.current
    return :expiring if certificate_expires_at < EXPIRING_DAYS.days.from_now

    :valid
  end

  def ready_to_issue?
    active? && %i[valid expiring].include?(certificate_status)
  end

  def nfe_certificate
    Nfe::Certificate.new(certificate.download, certificate_password)
  end

  private

  def normalize_cnpj
    self.cnpj = Nfe::Cnpj.digits(cnpj)
  end

  def cnpj_checksum
    errors.add(:cnpj, 'deve ser um CNPJ válido') if cnpj.present? && !Nfe::Cnpj.valid?(cnpj)
  end

  def certificate_matches_company
    data = certificate_file.present? ? certificate_file.read : nil
    if data.nil?
      return unless certificate.attached? && certificate_password_changed? && !new_record?

      data = certificate.download
    end

    if certificate_password.blank?
      errors.add(:certificate_password, 'é obrigatória para o certificado')
      return
    end

    cert = Nfe::Certificate.new(data, certificate_password)
    return errors.add(:certificate_file, 'está vencido') if cert.expired?
    return errors.add(:certificate_file, 'pertence a outro CNPJ') if cert.cnpj != cnpj

    self.certificate_expires_at = cert.expires_at
    self.certificate_subject = cert.subject
    self.certificate_cnpj = cert.cnpj
    if certificate_file.present?
      self.certificate = { io: StringIO.new(data), filename: 'certificado.pfx', content_type: 'application/x-pkcs12' }
    end
  rescue Nfe::Certificate::Error => e
    errors.add(:certificate_file, e.message)
  end
end
```

- [ ] **Step 4:** aplicar a migration no MySQL temporário e rodar → PASS. (Ajustar o teste `certificate_status ... expiring` se `attach` em record novo exigir `save` — nesse caso usar `Company.create!` com certificado real e `update_column(:certificate_expires_at, 10.days.from_now)`.)

---

### Task 5: Tela de Empresas

**Files:**
- Create: `app/controllers/companies_controller.rb`, `app/views/companies/{index,new,edit,_form}.html.erb`
- Modify: `config/routes.rb` (`resources :companies, except: [:show]`)
- Test: `test/controllers/companies_controller_test.rb`

**Interfaces:**
- Consumes: `Company` (Task 4), `Screen` `:companies` (Task 2).
- Produces: rotas `companies_path`, `new_company_path`, `edit_company_path(c)`, `company_path(c)`.

Espelhar `TransferLocationsController` e suas views (ler `app/views/transfer_locations/*` para o padrão de markup/CSS antes de escrever). Diferenças:
- `guard_screen :companies`.
- `company_params`: todos os campos exceto `certificate_expires_at/subject/cnpj`, mais `certificate_file` e `certificate_password`. No `update`, se `certificate_password` vier em branco e não houver arquivo novo, remover a chave do hash (mantém a atual).
- Formulário: `form_with model: @company, multipart: true`; seções Identificação, Endereço, Emissão (ambiente, série, próximo número), CFOP/Tributação, Certificado (input file `certificate_file`, senha `password_field` com `value: nil`, badge de status via `certificate_status`).
- Index: colunas Razão social, CNPJ, Ambiente, Certificado (badge: sem certificado / vencido / vence em N dias / válido), Ativa, ações.
- **Nunca renderizar** `certificate_password` (nem em value/atributo).

- [ ] **Step 1: Testes** (usuário sem acesso redireciona; admin cria empresa com dados válidos; cria com certificado e vê badge "válido"; certificado com CNPJ errado re-renderiza com erro; editar sem senha mantém certificado; `response.body` nunca contém a senha `senha123`; index lista a empresa; destroy remove).
- [ ] **Step 2:** rodar → FAIL.
- [ ] **Step 3:** implementar controller, views e rota.
- [ ] **Step 4:** rodar → PASS.

---

### Task 6: Dados fiscais em Produto, Cliente e Local de Transferência

**Files:**
- Create: `db/migrate/<ts>_add_fiscal_fields.rb`
- Modify: `app/controllers/{products,clients,transfer_locations}_controller.rb` (strong params), `app/views/{products/_form,clients/_form,transfer_locations/_form}.html.erb`
- Test: acrescentar em `test/controllers/transfer_locations_controller_test.rb` e criar `test/models/fiscal_fields_test.rb`

**Interfaces:**
- Produces: `products.ncm (string)`, `products.cest (string)`, `products.origin (integer, default 0, null: false)`, `products.commercial_unit (string, default 'UN', null: false)`, `clients.city_ibge_code (string)`, `clients.ie_indicator (integer, default 9, null: false; 1 contribuinte, 2 isento, 9 não contribuinte)`, `transfer_locations.city_ibge_code (string)`.

- [ ] **Step 1:** testes: (a) defaults `Product.new.origin == 0`, `commercial_unit == 'UN'`, `Client.new.ie_indicator == 9`; (b) `patch transfer_location_path` com `city_ibge_code: '3106200'` persiste; (c) idem para cliente e produto (ler o teste/controller existente de cada um para o padrão de login e parâmetros).
- [ ] **Step 2:** rodar → FAIL.
- [ ] **Step 3:** migration, `permit` dos novos campos e um bloco "Dados fiscais" em cada form (NCM com `maxlength: 8`, IBGE com `maxlength: 7`, select de `ie_indicator` com os 3 rótulos).
- [ ] **Step 4:** rodar → PASS.

---

### Task 7: Model `FiscalNote` e telas de lista/detalhe/XML

**Files:**
- Create: `db/migrate/<ts>_create_fiscal_notes.rb`, `app/models/fiscal_note.rb`, `app/controllers/fiscal_notes_controller.rb`, `app/views/fiscal_notes/{index,show}.html.erb`
- Modify: `app/models/company.rb` (`has_many :fiscal_notes, dependent: :restrict_with_error`), `app/models/b2b_order.rb` (`has_many :fiscal_notes, dependent: :nullify`), `config/routes.rb`
- Test: `test/models/fiscal_note_test.rb`, `test/controllers/fiscal_notes_controller_test.rb`

**Interfaces:**
- Produces: `FiscalNote` (`company`, `b2b_order` opcional, `number`, `series`, `access_key`, `environment`, `operation_nature`, `cfop_summary`, `status` enum `rascunho 0, assinada 1, autorizada 2, rejeitada 3, cancelada 4, erro 5`, `protocol`, `total_value decimal(12,2)`, `error_message text`, `issued_at`, `has_one_attached :xml`); `FiscalNote::ACTIVE_STATUSES = %w[rascunho assinada autorizada]`; `scope :active_statuses`; `FiscalNote.active_for?(order) -> Boolean`; `#xml_available?`. Rotas: `resources :fiscal_notes, only: [:index, :show, :new, :create] { member { get :xml } }` → `fiscal_notes_path`, `fiscal_note_path`, `new_fiscal_note_path(b2b_order_id:)`, `xml_fiscal_note_path`.

- [ ] **Step 1: Testes**
  - Model: `access_key` com 44 dígitos quando presente; `active_for?` é true com nota `assinada` e false com `erro`/`rejeitada`/`cancelada`; unicidade `[company_id, series, number]`.
  - Controller: sem acesso redireciona; index lista e filtra por `status` e `company_id`; show exibe chave e erro; `get xml_fiscal_note_path` devolve `application/xml` com o conteúdo anexado e 404/redirect quando não há XML; download exige a permissão.
- [ ] **Step 2:** rodar → FAIL.
- [ ] **Step 3:** implementar migration, model, controller (`guard_screen :fiscal_notes`; `xml` usa `send_data note.xml.download, type: 'application/xml', filename: "NFe#{note.access_key}.xml", disposition: 'attachment'`), views no padrão de `b2b_orders/index`, rotas.
- [ ] **Step 4:** rodar → PASS.

---

### Task 8: `Nfe::XmlBuilder`

**Files:**
- Create: `app/services/nfe/xml_builder.rb`
- Test: `test/services/nfe/xml_builder_test.rb`

**Interfaces:**
- Consumes: `Company` (Task 4).
- Produces:

```ruby
Nfe::XmlBuilder.new(
  company:, recipient:, items:, number:, series:, operation_nature:,
  issued_at:, cnf: nil   # cnf: 8 dígitos opcional (injetável em teste)
).call  # => Nfe::XmlBuilder::Result = Struct.new(:xml, :access_key, :total, keyword_init: true)
```

`recipient`: `{ name:, document: (CNPJ 14 ou CPF 11 dígitos), ie_indicator:, state_registration:, street:, number:, complement:, neighbourhood:, city:, city_ibge_code:, state:, zip:, phone:, email: }`.
`items` (cada): `{ code:, description:, ncm:, cest:, origin:, unit:, quantity:, unit_price:, cfop: }`.
Levanta `Nfe::XmlBuilder::Error` (pt-BR) para dado ausente (NCM, IBGE) ou situação tributária não suportada.
`Nfe::XmlBuilder.access_key_check_digit(digits43) -> Integer` (módulo 11, pesos 2..9 da direita).

Regras do XML (layout 4.00, namespace `http://www.portalfiscal.inf.br/nfe`):
- `infNFe Id="NFe<chave>" versao="4.00"`; `ide`: cUF, cNF, natOp, mod 55, serie, nNF, dhEmi (ISO-8601 com offset, fuso America/Sao_Paulo), tpNF 1, idDest (1 mesma UF, 2 outra), cMunFG (IBGE da empresa), tpImp 1, tpEmis 1, cDV, tpAmb (1/2), finNFe 1, indFinal 0, indPres 0, procEmi 0, verProc `Honey 1.0`.
- `emit`: CNPJ, xNome, xFant, enderEmit (xLgr, nro, xCpl se houver, xBairro, cMun, xMun, UF, CEP 8 dígitos, cPais 1058, xPais BRASIL, fone), IE, IM se houver, CNAE se houver **(IM e CNAE só juntos no layout: emitir CNAE apenas se IM presente)**, CRT.
- `dest`: CNPJ ou CPF, xNome, enderDest, indIEDest, IE se `ie_indicator == 1`, email se houver. **Em homologação, xNome do destinatário = `NF-E EMITIDA EM AMBIENTE DE HOMOLOGACAO - SEM VALOR FISCAL` e xProd do 1º item idem.**
- `det nItem`: prod (cProd, cEAN `SEM GTIN`, xProd, NCM, CEST se houver, CFOP, uCom, qCom `%.4f`, vUnCom `%.4f`, vProd `%.2f`, cEANTrib `SEM GTIN`, uTrib, qTrib, vUnTrib, indTot 1); imposto: ICMS (regimes 1/2 com `icms_situation` em 102/103/300/400 → `ICMSSN102{orig,CSOSN}`; regime 3 com CST 40/41/50 → `ICMS40{orig,CST}`; qualquer outra → `Error` "situação tributária não suportada"); PIS/COFINS (CST 04–09 → `PISNT/COFINSNT{CST}`; CST 49 ou 99 → `PISOutr/COFINSOutr{CST,vBC 0.00,pPIS/pCOFINS 0.0000,vPIS/vCOFINS 0.00}`; outro → `Error`).
- `total/ICMSTot` com todos os campos zerados exceto `vProd` e `vNF` (soma dos itens); `transp/modFrete 9`; `pag/detPag{tPag 90, vPag 0.00}`; `infAdic/infCpl` vazio omitido.
- Chave = cUF(2)+AAMM(4)+CNPJ(14)+mod(2)+série(3)+nNF(9)+tpEmis(1)+cNF(8)+DV(1). `cNF` aleatório de 8 dígitos, diferente de nNF.
- Serialização sem indentação (`save_with: AS_XML`) para não quebrar a canonicalização na assinatura.

- [ ] **Step 1: Testes** (com `Company.new(...)` em memória, sem banco):
  - DV: `access_key_check_digit('3519080803010000010055001000000001100000001'... )` — usar um vetor conhecido calculado à mão no teste (43 dígitos → DV esperado) e checar `access_key` de 44 dígitos com `cUF/AAMM/CNPJ/série/nNF` nas posições certas.
  - XML bem-formado (`Nokogiri::XML(xml) { |c| c.strict }`), `infNFe[@Id]` = `"NFe#{access_key}"`.
  - Totais: dois itens (2×10,00 e 1×5,50) → `vNF` = `25.50`.
  - `idDest` = 1 para destinatário na mesma UF e 2 em outra; CFOP vem do item.
  - Homologação mascara o xNome do destinatário e o xProd do 1º item; produção não.
  - Erros: item sem NCM ("NCM ausente para o item X"), destinatário sem IBGE, `icms_situation` '500' → erro de situação não suportada.
  - Simples usa `ICMSSN102`; regime 3 CST 40 usa `ICMS40`.
- [ ] **Step 2:** rodar → FAIL.
- [ ] **Step 3:** implementar com `Nokogiri::XML::Builder`, formatando números com `format('%.4f', ...)`.
- [ ] **Step 4:** rodar → PASS.

---

### Task 9: `Nfe::Signer`

**Files:**
- Create: `app/services/nfe/signer.rb`
- Test: `test/services/nfe/signer_test.rb`

**Interfaces:**
- Consumes: `Nfe::Certificate` (Task 3), XML de `Nfe::XmlBuilder` (Task 8).
- Produces: `Nfe::Signer.new(certificate).sign(xml) -> String` (XML com `<Signature>` irmã de `infNFe`, dentro de `NFe`). Levanta `Nfe::Signer::Error` se não achar `infNFe` com `Id`.

Algoritmo (XMLDSig enveloped, exigido pelo layout): 
1. Parsear `xml` (`Nokogiri::XML(xml) { |c| c.noblanks }`), localizar `infNFe` (`Id`).
2. `digest = Base64(SHA1(inf.canonicalize(Nokogiri::XML::XML_C14N_1_0)))`.
3. Montar `Signature` (xmlns `http://www.w3.org/2000/09/xmldsig#`) após `infNFe`: `SignedInfo` (`CanonicalizationMethod` `http://www.w3.org/TR/2001/REC-xml-c14n-20010315`, `SignatureMethod` `http://www.w3.org/2000/09/xmldsig#rsa-sha1`, `Reference URI="#<Id>"` com `Transforms` (`enveloped-signature` e c14n), `DigestMethod` sha1, `DigestValue`), `SignatureValue` = `Base64(RSA-SHA1(canonicalize(SignedInfo já dentro do documento)))`, `KeyInfo/X509Data/X509Certificate` = `certificate.base64_der`.
4. Serializar sem indentação (`AS_XML`).

- [ ] **Step 1: Testes** (certificado de `NfeTestCertificate`, XML de `XmlBuilder` com dados mínimos):
  - o XML assinado tem `Signature` com `Reference/@URI == "#NFe<chave>"`;
  - **verificação real**: recomputar o digest do `infNFe` do XML assinado e comparar com `DigestValue`; canonicalizar `SignedInfo` do XML assinado e verificar `SignatureValue` com a chave pública do certificado (`public_key.verify(SHA1, sig, data)` → true);
  - adulterar um valor dentro de `infNFe` depois de assinar → digest não bate (prova que a assinatura protege o conteúdo);
  - XML sem `infNFe` → `Nfe::Signer::Error`.
- [ ] **Step 2:** rodar → FAIL.
- [ ] **Step 3:** implementar.
- [ ] **Step 4:** rodar → PASS. Se `sign` com SHA1 for recusado pelo OpenSSL 3 do ambiente, registrar o erro literal e tratar (não trocar o algoritmo: o layout exige SHA-1).

---

### Task 10: `Nfe::Generator`

**Files:**
- Create: `app/services/nfe/generator.rb`
- Test: `test/services/nfe/generator_test.rb`

**Interfaces:**
- Consumes: `Company`, `FiscalNote`, `B2bOrder`/`B2bOrderItem`/`Client`/`TransferLocation`/`Product`, `Nfe::XmlBuilder`, `Nfe::Signer`, `Nfe::Certificate`.
- Produces: `Nfe::Generator.call(order:, company:) -> FiscalNote` (status `assinada`, XML anexado); levanta `Nfe::Generator::Error` (pt-BR) sem criar nota nem consumir número.

Comportamento:
1. Erros de pré-condição: empresa sem `ready_to_issue?` ("Empresa sem certificado válido"), `FiscalNote.active_for?(order)` ("Já existe nota ativa para este pedido").
2. Destinatário: atacado → `order.client` (`registration` → document, `business_name.presence || responsible_name`, `state_registration`, `ie_indicator`, endereço, `city_ibge_code`, `state`, `zip`, `phone`, `email`); transferência → `order.transfer_location` (`registration`, `name`, `state_registration` (indicador 1 se houver IE, senão 9), endereço, `city_ibge_code`).
3. Itens: para cada `order.b2b_order_items`, `Product.find_by(sku:)`; reunir **todos** os SKUs sem produto/NCM numa única mensagem ("Dados fiscais ausentes: NCM do SKU A, B; IBGE do destinatário").
   Preço unitário = `price - discount`. CFOP por tipo (venda/transferência) e UF igual/diferente (campos da empresa).
4. `ActiveRecord::Base.transaction { company.with_lock { ... } }`: número = `company.next_nfe_number`; builder (`operation_nature` conforme tipo); assinatura com `company.nfe_certificate`; `FiscalNote.create!(company:, b2b_order: order, number:, series: company.nfe_series, access_key:, environment: company.environment, operation_nature:, cfop_summary: cfops.uniq.join(', '), status: :assinada, total_value:, issued_at:)`, `note.xml.attach(io: StringIO.new(signed), filename: "NFe#{key}.xml", content_type: 'application/xml')`, `company.update!(next_nfe_number: number + 1)`.
5. Qualquer exceção (`Nfe::XmlBuilder::Error`, `Nfe::Signer::Error`, `Nfe::Certificate::Error`, `ActiveRecord::RecordInvalid`) é convertida em `Nfe::Generator::Error` e a transação desfaz (número não avança).

- [ ] **Step 1: Testes** (criar Company com `NfeTestCertificate`, Client/TransferLocation, Products com `ncm`, B2bOrder com item — o pedido precisa de item para passar na validação):
  - caminho feliz atacado: nota `assinada`, XML anexado e assinado (contém `<Signature`), `next_nfe_number` avançou, CFOP 5102 (mesma UF) e 6102 (UF diferente);
  - caminho feliz transferência: CFOP 5152/6152 e `operation_nature` de transferência, destinatário = local;
  - preço unitário considera o desconto;
  - SKU sem NCM: `Nfe::Generator::Error` listando o SKU, **nenhuma** `FiscalNote` criada e `next_nfe_number` inalterado;
  - segunda geração para o mesmo pedido → erro de nota ativa; depois de mudar a primeira para `erro`, gera de novo com número seguinte;
  - empresa sem certificado → erro.
- [ ] **Step 2:** rodar → FAIL.
- [ ] **Step 3:** implementar.
- [ ] **Step 4:** rodar → PASS.

---

### Task 11: Botão "Gerar nota fiscal" nos pedidos

**Files:**
- Modify: `app/controllers/fiscal_notes_controller.rb` (`new`, `create`), `app/views/fiscal_notes/new.html.erb` (criar), `app/views/b2b_orders/index.html.erb` (ícone na coluna Ações), `app/views/b2b_orders/edit.html.erb` (botão no cabeçalho)
- Test: `test/controllers/fiscal_notes_generation_test.rb`

**Interfaces:**
- Consumes: `Nfe::Generator.call(order:, company:)` (Task 10), rotas da Task 7.
- Produces: `GET /fiscal_notes/new?b2b_order_id=ID` (resumo do pedido + `select` com `Company.ready_to_issue.order(:legal_name)` + botão "Gerar"), `POST /fiscal_notes` (`b2b_order_id`, `company_id`) → sucesso: redireciona para `fiscal_note_path` com notice "Nota fiscal gerada e assinada (não transmitida à SEFAZ)."; `Nfe::Generator::Error`: re-renderiza `new` com o erro em `flash.now[:alert]` (status 422).

- [ ] **Step 1: Testes**: sem permissão `fiscal_notes` o ícone não aparece nas listas e `new` redireciona; com permissão o ícone aparece nas duas listas (atacado e transferência) e no edit; `new` lista só empresas prontas; `create` com dados completos cria a nota e redireciona; `create` com NCM faltando volta 422 mostrando o SKU e não cria nota; empresa fora da lista (sem certificado) é recusada; pedido inexistente → 404.
- [ ] **Step 2:** rodar → FAIL.
- [ ] **Step 3:** implementar (ícone `fa-file-invoice` só se `current_user.can_access_screen?('fiscal_notes')`; usar `orders_path_for` etc. já existentes nas views de pedidos).
- [ ] **Step 4:** rodar → PASS.

---

### Task 12: Verificação final

- [ ] Rodar todos os testes novos juntos: `bin/rails test test/config test/models/company_test.rb test/models/fiscal_note_test.rb test/models/fiscal_fields_test.rb test/services/nfe test/controllers/companies_controller_test.rb test/controllers/fiscal_notes_controller_test.rb test/controllers/fiscal_notes_generation_test.rb test/models/screen_test.rb test/controllers/sidebar_test.rb`.
- [ ] Rodar `test/controllers/b2b_orders_controller_test.rb`, `b2b_orders_kind_separation_test.rb`, `flash_messages_test.rb` e comparar com a lista de falhas preexistentes (não pode haver falha nova).
- [ ] Conferir `git status`: só arquivos deste plano + migrations; `db/schema.rb` sem os índices únicos removidos do banco de teste.
- [ ] Encerrar o MySQL temporário.
- [ ] Relatório final ao usuário: migrations a aplicar (`bin/rails db:migrate` — atenção: dev = banco compartilhado), variáveis `ACTIVE_RECORD_ENCRYPTION_*` para o Heroku, permissões `companies`/`fiscal_notes` a conceder em Perfis, limites (sem SEFAZ, validação por contador).
