require 'test_helper'
require 'minitest/mock'
require_relative '../support/nfe_company_factory'

# Nota de remessa do Abastecimento Lojas: uma nota a mais do pedido (ex.: 5905 para o depósito do Correios, a
# CLI CONTAGEM), com empresa, natureza e destinatário padrão nas Configurações e destinatário trocável por pedido.
class StockTransferRemessaNoteTest < ActionDispatch::IntegrationTest
  include NfeCompanyFactory

  def setup
    @admin = User.create!(name: 'Admin', email: 'admin_remessa@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @company = create_nfe_company
    @remessa = @company.operation_natures.create!(description: 'Remessa para depósito fechado ou armazém geral', kind: :other, cfop: '?905',
                                                  final_consumer: false, icms_situation: '41', pis_cst: '08', cofins_cst: '08')
    @transfer = @company.operation_natures.create!(description: 'Transferência entre Filiais - MG', kind: :transfer, cfop: '?152',
                                                   final_consumer: false, icms_situation: '41', pis_cst: '08', cofins_cst: '08')
    @location = TransferLocation.create!(name: 'Loja Centro', registration: '25.405.327/0004-17', street: 'Rua A', number: '10',
                                         neighbourhood: 'Centro', city: 'BH', state: 'MG', zip: '30000-000', city_ibge_code: '3106200')
    Product.create!(sku: 'SKU1', shopify_product_name: 'Legging', ncm: '61046300')
    @order = B2bOrder.new(kind: :stock_transfer, user: @admin, transfer_location: @location, price_list: :transfer, receiver_name: 'Maria')
    @order.b2b_order_items.build(sku: 'SKU1', name: 'Legging', quantity: 1, price: 10)
    @order.save!
    sign_in @admin
  end

  def configure_remessa
    B2bSetting.current.update!(supply_issuer_company: @company, supply_nature: @transfer, remessa_issuer_company: @company, remessa_nature: @remessa)
  end

  def emit_remessa(env = 'homologacao')
    authorize = ->(note, **) { note.update!(status: :autorizada, protocol: '1') }
    Nfe::Transmitter.stub(:call, authorize) do
      post b2b_order_fiscal_notes_path(b2b_order_id: @order.id), params: { environment: env, role: 'remessa' }
    end
  end

  test 'the settings show the remessa section with CLI CONTAGEM already filled and save company, nature and recipient' do
    get stock_transfer_settings_path

    assert_select "select[name='b2b_setting[remessa_issuer_company_id]']"
    assert_select "select[name='b2b_setting[remessa_nature_id]'] option[value='#{@remessa.id}']"
    assert_select "input[name='b2b_setting[remessa_recipient][name]'][value='CLI CONTAGEM']"
    assert_select "input[name='b2b_setting[remessa_recipient][document]'][value='34.028.316/9005-20']"
    assert_select "input[name='b2b_setting[remessa_recipient][state_registration]'][value='0620144620013']"

    recipient = B2bSetting::REMESSA_DEFAULT_RECIPIENT.merge('complement' => 'Docas 1 a 10')
    patch stock_transfer_settings_path, params: { b2b_setting: { remessa_issuer_company_id: @company.id, remessa_nature_id: @remessa.id,
                                                                 remessa_recipient: recipient } }

    setting = B2bSetting.current
    assert_equal [@company, @remessa], [setting.remessa_issuer, setting.remessa_nature]
    assert_equal 'Docas 1 a 10', setting.remessa_recipient_data['complement']
  end

  test 'the B2C transfer settings have no remessa section' do
    get b2c_transfer_settings_path
    assert_select "select[name='b2b_setting[remessa_nature_id]']", count: 0
  end

  test 'the Nota fiscal tab of a stock transfer has the remessa card; it emits the remessa apart from the transfer note' do
    configure_remessa

    get edit_stock_transfer_path(@order, tab: 'nota')
    assert_select '#remessaNote', text: /CLI CONTAGEM/
    assert_select "#remessaNote form[action='#{b2b_order_fiscal_notes_path(b2b_order_id: @order.id)}'] input[name=role][value=remessa]"

    emit_remessa
    note = FiscalNote.last
    assert note.remessa?
    assert note.autorizada?
    assert_equal '5905', note.cfop_summary

    get edit_stock_transfer_path(@order, tab: 'nota')
    assert_select '#remessaNote .it-slot--homologacao', text: /nº #{note.number}/
    assert_select '.it-fiscal-card:not(#remessaNote) .it-slot--homologacao', text: /Nenhuma nota de homologação/
    assert_nil @order.nf_details_lock
    assert_empty FiscalNote.latest_by_order([@order.id])
  end

  test 'the recipient can be changed only for this order and back to the default' do
    configure_remessa
    data = B2bSetting::REMESSA_DEFAULT_RECIPIENT.merge('name' => 'Armazém Novo', 'number' => '99')

    patch remessa_recipient_b2b_order_fiscal_notes_path(b2b_order_id: @order.id), params: { remessa_recipient: data }

    assert_redirected_to edit_stock_transfer_path(@order, tab: 'nota')
    assert_equal 'Armazém Novo', @order.reload.remessa_recipient_data['name']
    assert_equal 'CLI CONTAGEM', B2bSetting.current.remessa_recipient_data['name']

    patch remessa_recipient_b2b_order_fiscal_notes_path(b2b_order_id: @order.id), params: { reset: '1' }
    assert_equal 'CLI CONTAGEM', @order.reload.remessa_recipient_data['name']
  end

  test 'without the remessa nature the card says where to choose it' do
    get edit_stock_transfer_path(@order, tab: 'nota')
    assert_select '#remessaNote', text: /Escolha a (empresa|natureza) da nota de remessa/
  end

  test 'wholesale orders have no remessa card' do
    client = Client.create!(responsible_name: 'Lojista', registration: '45.723.174/0001-10')
    sale = B2bOrder.new(kind: :sale, user: @admin, client: client)
    sale.b2b_order_items.build(sku: 'SKU1', name: 'Legging', quantity: 1, price: 10)
    sale.save!

    get edit_b2b_order_path(sale, tab: 'nota')
    assert_select '#remessaNote', count: 0
  end

  test 'the Log02 XML step uses the transfer note, never the remessa one' do
    configure_remessa
    @company.update!(environment: :producao)
    @order.update_columns(correios_order_id: 25_000_001)
    emit_remessa('producao')
    remessa = FiscalNote.last
    assert remessa.autorizada?

    generated = []
    fake = lambda do |order:, company:, nature:, environment: nil, role: nil|
      generated << role
      FiscalNote.create!(company:, b2b_order: order, number: 900, series: 1, status: :rascunho, environment:)
    end
    Nfe::Generator.stub(:call, fake) { HoneyB2bLog.send_xml(@order) }

    assert_equal [nil], generated, 'gera a nota de transferência, sem usar a remessa autorizada'
  end
end
