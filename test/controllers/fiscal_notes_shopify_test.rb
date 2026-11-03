require 'test_helper'
require 'webmock/minitest'
require 'minitest/mock'
require_relative '../support/shopify_order_factory'
require_relative '../support/nfe_company_factory'

class FiscalNotesShopifyTest < ActionDispatch::IntegrationTest
  include NfeCompanyFactory

  def setup
    @admin = User.create!(name: 'Admin Notas', email: 'admin_notas_shopify@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @company = create_nfe_company
    @nature = create_sale_nature(@company)
    Product.create!(sku: 'SKU-1', ncm: '61091000')
    Product.create!(sku: 'SKU-2', ncm: '62034200')
    stub_request(:get, %r{viacep.com.br}).to_return(
      status: 200, headers: { 'Content-Type' => 'application/json' },
      body: { localidade: 'Belo Horizonte', uf: 'MG', bairro: 'Funcionários', ibge: '3106200' }.to_json
    )
    sign_in @admin
  end

  def with_order(node = ShopifyOrderFactory.node, &block)
    Nfe::ShopifyOrder.stub(:fetch_node, node, &block)
  end

  def recipient_params(overrides = {})
    { name: 'Maria Cliente', document: '529.982.247-25', ie_indicator: '9', street: 'Rua das Flores', number: '10',
      neighbourhood: 'Funcionários', city: 'Belo Horizonte', state: 'MG', zip: '30140-071', city_ibge_code: '3106200' }
      .merge(overrides)
  end

  def post_emission(recipient: recipient_params)
    post create_from_shopify_fiscal_notes_path, params: {
      shopify_order_id: '6100000000001', emission: "#{@company.id}:#{@nature.id}", freight_mode: '0',
      recipient: recipient, payment: { method: '03', installments: '3', description: 'cartão' }
    }
  end

  test 'shows the order with the prefilled recipient, items and nature' do
    with_order { get shopify_fiscal_notes_path(order: '1001') }

    assert_response :success
    assert_select '.nfe-hero__title', text: '#1001'
    assert_select 'input[name="recipient[document]"][value="52998224725"]'
    assert_select 'input[name="recipient[city_ibge_code]"][value="3106200"]'
    assert_select 'select[name="emission"] option[selected]', text: /Venda Online/
    assert_select 'select[name="payment[method]"] option[selected][value="03"]'
    assert_select '.ncm-ok', count: 2
  end

  test 'order not found shows a message' do
    with_order(nil) { get shopify_fiscal_notes_path(order: '999') }
    assert_response :success
    assert_select '.flash-messages-container .alert', text: /não encontrado/
  end

  test 'store sale with NFC-e cannot be issued' do
    node = ShopifyOrderFactory.attribute(ShopifyOrderFactory.node, 'nfce-key', '1' * 44)
    with_order(node) { get shopify_fiscal_notes_path(order: '1001') }
    assert_select '.nfe-flag--block', text: /NFC-e/
    assert_select 'input[type=submit][disabled]'
  end

  test 'issues, transmits and lands on the note' do
    transmitted = nil
    fake = ->(note, **) { transmitted = note; note.update!(status: :autorizada, protocol: '1312600001'); note }
    with_order do
      Nfe::Transmitter.stub(:call, fake) { assert_difference('FiscalNote.count', 1) { post_emission } }
    end

    note = FiscalNote.last
    assert_equal note, transmitted
    assert_redirected_to fiscal_note_path(note)
    assert_equal '#1001', note.shopify_order_name
    follow_redirect!
    assert_select '.sefaz-result--ok', text: /Autorizada/
  end

  test 'missing data re-renders the form keeping what was typed' do
    with_order { post_emission(recipient: recipient_params(document: '111', name: 'Nome digitado')) }

    assert_response :unprocessable_entity
    assert_select '.flash-messages-container .alert', text: /CPF\/CNPJ válido/
    assert_select 'input[name="recipient[name]"][value="Nome digitado"]'
    assert_equal 0, FiscalNote.count
  end

  test 'DANFE downloads as a PDF from the stored XML' do
    note = with_order { Nfe::Transmitter.stub(:call, ->(n, **) { n }) { post_emission }; FiscalNote.last }
    get fiscal_note_path(note)
    assert_select "a[href='#{danfe_fiscal_note_path(note)}']", text: /Baixar DANFE/

    get danfe_fiscal_note_path(note)
    assert_response :success
    assert_equal 'application/pdf', response.media_type
    assert response.body.start_with?('%PDF')
    assert_match(/attachment; filename="DANFE-#{note.access_key}.pdf"/, response.headers['Content-Disposition'])
  end

  test 'transmit and consult buttons call SEFAZ for the note' do
    note = with_order { Nfe::Transmitter.stub(:call, ->(n, **) { n }) { post_emission }; FiscalNote.last }
    calls = []
    fake = ->(n, **opts) { calls << opts; n.update!(status: :rejeitada, error_message: 'Rejeição 225: Falha'); n }
    Nfe::Transmitter.stub(:call, fake) do
      post transmit_fiscal_note_path(note)
      assert_redirected_to fiscal_note_path(note)
      post consult_fiscal_note_path(note)
    end
    assert_equal [{}, { consult: true }], calls
    follow_redirect!
    assert_select '.sefaz-result--bad', text: /Rejeição 225/
    assert_select 'a', text: /Corrigir e emitir de novo/
  end

  test 'index shows the environment switch and toggling asks for production' do
    get fiscal_notes_path
    assert_select '.env-switch--hom .env-switch__label', text: 'Homologação'

    patch toggle_environment_company_path(@company), headers: { 'HTTP_REFERER' => fiscal_notes_url }
    assert @company.reload.producao?
    follow_redirect!
    assert_select '.env-card--prod'

    patch toggle_environment_company_path(@company)
    assert @company.reload.homologacao?
  end

  # SQL executado durante o bloco (sem cache, schema e transações).
  def sql_during(&block)
    sqls = []
    collect = ->(*, payload) { sqls << payload[:sql] unless payload[:name].in?(%w[SCHEMA TRANSACTION]) || payload[:cached] }
    ActiveSupport::Notifications.subscribed(collect, 'sql.active_record', &block)
    sqls
  end

  def create_notes(count)
    count.times do
      seq = FiscalNote.maximum(:number).to_i + 1
      note = FiscalNote.create!(company: @company, number: seq, series: 1, environment: :homologacao, status: :autorizada,
                                access_key: format('%044d', seq), total_value: 10, operation_nature: 'Venda Online',
                                cfop_summary: '5102', issued_at: Time.current)
      note.xml.attach(io: StringIO.new('<nfeProc/>'), filename: "n#{seq}.xml", content_type: 'application/xml')
    end
  end

  test 'notes list loads XMLs, companies and orders in one query each, whatever the number of notes' do
    create_notes(8)
    sqls = sql_during { get fiscal_notes_path }

    assert_response :success
    assert_select 'a[aria-label="Baixar DANFE"]', count: 8
    assert_equal 1, sqls.count { |sql| sql.include?('`active_storage_attachments`') && sql.include?("'FiscalNote'") }
    # A lista só precisa saber se há XML anexado: o arquivo (blob) nem é consultado.
    assert_equal 0, sqls.count { |sql| sql.include?('FROM `active_storage_blobs`') }
  end

  test 'companies list loads the certificates in one query' do
    create_nfe_company(cnpj: '45.997.418/0001-53')
    create_nfe_company(cnpj: '11.444.777/0001-61')
    sqls = sql_during { get companies_path }

    assert_response :success
    assert_equal 1, sqls.count { |sql| sql.include?('`active_storage_attachments`') && sql.include?("'Company'") }
  end

  test 'recent site orders are filtered in the database: only checkout orders without a production note' do
    site = Order.create!(shopify_order_id: 'SITE-1', shopify_creation_date: 1.day.ago, current_total_price: 100,
                         note_attributes: [{ 'name' => 'additional_cpf_cnpj', 'value' => '52998224725' }])
    Order.create!(shopify_order_id: 'POS-1', shopify_creation_date: 1.day.ago, current_total_price: 50,
                  note_attributes: [{ 'name' => 'nfce-key', 'value' => '1' * 44 }])
    issued = Order.create!(shopify_order_id: 'SITE-2', shopify_creation_date: 1.day.ago, current_total_price: 70,
                           note_attributes: [{ 'name' => 'additional_cpf_cnpj', 'value' => '52998224725' }])
    FiscalNote.create!(company: @company, order: issued, number: 1, series: 1, environment: :producao, status: :autorizada,
                       access_key: '1' * 44, total_value: 70, operation_nature: 'Venda Online', cfop_summary: '5102')

    get shopify_fiscal_notes_path
    assert_select "a[href='#{shopify_fiscal_notes_path(order: site.shopify_order_id)}']"
    assert_select "a[href='#{shopify_fiscal_notes_path(order: 'POS-1')}']", count: 0
    assert_select "a[href='#{shopify_fiscal_notes_path(order: 'SITE-2')}']", count: 0
  end
end
