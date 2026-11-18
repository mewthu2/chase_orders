require 'test_helper'
require 'minitest/mock'
require_relative '../support/nfe_company_factory'

# Empresa em homologação não emite nota de produção: os botões ficam desativados, com aviso e link para ligar a
# produção, e o servidor recusa o envio mesmo que o pedido chegue por fora da tela.
class ProductionEmissionLockTest < ActionDispatch::IntegrationTest
  include NfeCompanyFactory

  NEVER = ->(*, **) { raise 'não devia transmitir' }
  XML = '<NFe xmlns="http://www.portalfiscal.inf.br/nfe"/>'.freeze

  def setup
    @admin = User.create!(name: 'Admin', email: 'admin_lock@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @company = create_nfe_company(environment: :homologacao, next_nfe_number: 500)
    @nature = @company.operation_natures.create!(description: 'Transferência entre Filiais - MG', kind: :transfer, cfop: '?152',
                                                 final_consumer: false, icms_situation: '41', pis_cst: '08', cofins_cst: '08')
    @location = TransferLocation.create!(name: 'Loja Centro', registration: '25.405.327/0004-17', street: 'Rua A', number: '10',
                                         neighbourhood: 'Centro', city: 'BH', state: 'MG', zip: '30000-000', city_ibge_code: '3106200')
    Product.create!(sku: 'SKU1', shopify_product_name: 'Legging', ncm: '61046300')
    @order = B2bOrder.new(kind: :stock_transfer, user: @admin, transfer_location: @location, price_list: :transfer, receiver_name: 'Maria')
    @order.b2b_order_items.build(sku: 'SKU1', name: 'Legging', quantity: 1, price: 10)
    @order.save!
    B2bSetting.current.update!(supply_issuer_company: @company, supply_nature: @nature)
    sign_in @admin
  end

  def production_note(status, company: @company, **attrs)
    note = FiscalNote.create!(company:, number: 77, series: company.nfe_series, environment: :producao, status:, **attrs)
    note.xml.attach(io: StringIO.new(XML), filename: 'nota.xml', content_type: 'application/xml')
    note
  end

  def unlock_href(company = @company)
    fiscal_notes_path(anchor: "empresa-#{company.id}")
  end

  def internal_transfer_with_origin(company)
    origin = Location.create!(slug: 'bh_shopping', name: 'BH Shopping', shopify_location_id: '222', company:)
    destination_company = create_nfe_company(legal_name: 'Chase Lagoa Ltda', cnpj: '45.723.174/0001-10', state_registration: '87654321')
    destination = Location.create!(slug: 'lagoa_seca', name: 'Lagoa Seca', shopify_location_id: '111', company: destination_company)
    product = Product.create!(sku: 'SKU-A', shopify_product_name: 'Camiseta', shopify_inventory_item_id: '9001', ncm: '61091000', cost: '20.00', price: '99.90')
    transfer = InternalTransfer.new(destination_location: destination, requested_by: @admin, approval_status: :aprovada)
    shipment = transfer.shipments.build(origin_location: origin)
    shipment.items.build(product:, quantity: 2)
    transfer.save!
    [transfer, shipment]
  end

  test 'order tab disables the production button and links to the company switch' do
    get edit_stock_transfer_path(@order, tab: 'nota')

    assert_response :success
    assert_select '.it-slot--producao .nf-prod-lock button[disabled]', text: /Emitir nota de produção/
    assert_select ".it-slot--producao .nf-prod-lock a[href='#{unlock_href}']"
    assert_select ".it-slot--producao form input[name='environment'][value='producao']", count: 0
    assert_select ".it-slot--homologacao form input[name='environment'][value='homologacao']"
  end

  test 'order tab keeps the production button when the company is in production' do
    @company.update!(environment: :producao)

    get edit_stock_transfer_path(@order, tab: 'nota')

    assert_select ".it-slot--producao form input[name='environment'][value='producao']"
    assert_select '.nf-prod-lock', count: 0
  end

  test 'the server refuses a production note for an order while the company is in homologation' do
    Nfe::Transmitter.stub(:call, NEVER) do
      post b2b_order_fiscal_notes_path(b2b_order_id: @order.id), params: { environment: 'producao' }
    end

    assert_match(/está em homologação/, flash[:alert])
    assert_empty FiscalNote.where(b2b_order_id: @order.id)
    assert_equal 500, @company.reload.next_nfe_number
  end

  test 'a production draft of an order stays a draft while the company is in homologation' do
    note = production_note(:rascunho, b2b_order: @order)

    get edit_stock_transfer_path(@order, tab: 'nota')
    assert_select '.it-slot--producao .nf-prod-lock button[disabled]', text: /Emitir na SEFAZ/

    Nfe::Transmitter.stub(:call, NEVER) { post transmit_b2b_order_fiscal_note_path(@order, note) }
    assert_match(/está em homologação/, flash[:alert])
    assert note.reload.rascunho?
  end

  test 'a production note without an answer can still be consulted' do
    note = production_note(:erro, b2b_order: @order)
    consulted = nil

    get edit_stock_transfer_path(@order, tab: 'nota')
    assert_select '.it-slot--producao form button', text: /Consultar na SEFAZ/

    Nfe::Transmitter.stub(:call, ->(n, **opts) { consulted = opts[:consult]; n }) { post transmit_b2b_order_fiscal_note_path(@order, note) }
    assert_equal true, consulted
  end

  test 'internal transfer tab disables the production button and the server refuses it' do
    transfer, shipment = internal_transfer_with_origin(@company)
    @company.operation_natures.first.update!(default_for_kind: true)

    get edit_internal_transfer_path(transfer, tab: 'nota')
    assert_select '.it-slot--producao .nf-prod-lock button[disabled]', text: /Emitir nota de produção/
    assert_select ".it-slot--producao .nf-prod-lock a[href='#{unlock_href}']"

    Nfe::Transmitter.stub(:call, NEVER) do
      post internal_transfer_shipment_fiscal_notes_path(transfer, shipment), params: { environment: 'producao' }
    end
    assert_match(/está em homologação/, flash[:alert])
    assert_empty shipment.fiscal_notes.reload
  end

  test 'a production draft of a shipment stays a draft while the company is in homologation' do
    transfer, shipment = internal_transfer_with_origin(@company)
    note = production_note(:rascunho, internal_transfer_shipment: shipment)

    Nfe::Transmitter.stub(:call, NEVER) { post transmit_internal_transfer_shipment_fiscal_note_path(transfer, shipment, note) }

    assert_match(/está em homologação/, flash[:alert])
    assert note.reload.rascunho?
  end

  test 'note page disables sending a production note and the server refuses it' do
    note = production_note(:rascunho)

    get fiscal_note_path(note)
    assert_select '.nf-prod-lock button[disabled]', text: /Emitir na SEFAZ/
    assert_select ".nf-prod-lock a[href='#{unlock_href}']"
    assert_select "form[action='#{transmit_fiscal_note_path(note)}']", count: 0

    Nfe::Transmitter.stub(:call, NEVER) { post transmit_fiscal_note_path(note) }
    assert_match(/está em homologação/, flash[:alert])
    assert note.reload.rascunho?
  end

  test 'the link lands on the company card that has the production switch' do
    get fiscal_notes_path

    assert_select "#empresa-#{@company.id} form[action='#{toggle_environment_company_path(@company)}']"
  end

  test 'the transmitter refuses a production note of a company in homologation' do
    note = production_note(:assinada)

    error = assert_raises(Nfe::Transmitter::Error) { Nfe::Transmitter.new(note, client: Object.new).call }
    assert_match(/está em homologação/, error.message)
  end

  test 'the transmitter still consults a production note of a company in homologation' do
    note = production_note(:erro, access_key: '3' * 44)
    response = Nokogiri::XML('<retConsSitNFe xmlns="http://www.portalfiscal.inf.br/nfe"><cStat>217</cStat><xMotivo>Nao consta</xMotivo></retConsSitNFe>')
    client = Object.new
    client.define_singleton_method(:consult) { |_key| response }

    Nfe::Transmitter.new(note, consult: true, client:).call

    assert note.reload.assinada?
  end
end

class ProductionUnlockPathTest < ActionView::TestCase
  include FiscalNotesHelper

  Permissions = Struct.new(:companies_edit, :fiscal_view)

  def setup
    @permissions = Permissions.new(true, true)
    @company = Company.new(id: 9, active: true)
  end

  def screen_can?(screen, _action = :view)
    screen == :companies ? @permissions.companies_edit : @permissions.fiscal_view
  end

  test 'goes to the production switch of the company' do
    assert_equal '/fiscal_notes#empresa-9', production_unlock_path(@company)
  end

  test 'goes to the company form when the switch is out of reach' do
    @permissions.fiscal_view = false
    assert_equal '/companies/9/edit', production_unlock_path(@company)

    @permissions.fiscal_view = true
    @company.active = false
    assert_equal '/companies/9/edit', production_unlock_path(@company)
  end

  test 'has no link for who cannot change companies' do
    @permissions.companies_edit = false
    assert_nil production_unlock_path(@company)
  end
end
