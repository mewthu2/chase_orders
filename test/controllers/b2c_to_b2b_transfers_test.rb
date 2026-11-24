require 'test_helper'
require 'minitest/mock'
require 'webmock/minitest'
require_relative '../support/nfe_company_factory'

# Transferência B2C → B2B: não entra no Log02 nem no Correios; só gera a nota de transferência (filial B2C) e a de
# remessa (filial B2B), com empresas e naturezas nas Configurações da tela.
class B2cToB2bTransfersTest < ActionDispatch::IntegrationTest
  include NfeCompanyFactory

  def setup
    @admin = User.create!(name: 'Admin', email: 'admin_b2c_b2b@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @b2c = create_nfe_company(legal_name: 'Chase Filial B2C', cnpj: '11.222.333/0001-81')
    @b2b = create_nfe_company(legal_name: 'Chase Filial B2B', cnpj: '45.723.174/0001-10', state_registration: '87654321')
    @transfer = @b2c.operation_natures.create!(description: 'Transferência entre Filiais - MG', kind: :transfer, cfop: '?152',
                                               final_consumer: false, icms_situation: '41', pis_cst: '08', cofins_cst: '08')
    @remessa = @b2b.operation_natures.create!(description: 'Remessa', kind: :other, cfop: '?905',
                                              final_consumer: false, icms_situation: '41', pis_cst: '08', cofins_cst: '08')
    Product.create!(sku: 'SKU1', shopify_product_name: 'Legging', ncm: '61046300')
    sign_in @admin
  end

  def configure
    B2bSetting.current.update!(b2c_to_b2b_issuer_company: @b2c, b2c_to_b2b_nature: @transfer,
                               b2c_to_b2b_remessa_issuer_company: @b2b, b2c_to_b2b_remessa_nature: @remessa)
  end

  def build_order(**attrs)
    order = B2bOrder.new({ kind: :b2c_transfer, transfer_direction: :b2c_to_b2b, user: @admin, price_list: :transfer }.merge(attrs))
    order.b2b_order_items.build(sku: 'SKU1', name: 'Legging', quantity: 2, price: 10)
    order.save!
    order
  end

  def emit(order, env, role = nil)
    authorize = ->(note, **) { note.update!(status: :autorizada, protocol: '1') }
    Nfe::Transmitter.stub(:call, authorize) do
      post b2b_order_fiscal_notes_path(b2b_order_id: order.id), params: { environment: env, role: role }.compact
    end
  end

  test 'the settings page has both directions and saves the B2C to B2B companies, natures and recipient' do
    get b2c_transfer_settings_path

    assert_select "select[name='b2b_setting[b2c_issuer_company_id]']"
    assert_select "#b2cToB2bSettings select[name='b2b_setting[b2c_to_b2b_issuer_company_id]']"
    assert_select "#b2cToB2bSettings select[name='b2b_setting[b2c_to_b2b_remessa_nature_id]'] option[value='#{@remessa.id}']"
    assert_select "#b2cToB2bSettings input[name='b2b_setting[b2c_to_b2b_remessa_recipient][name]'][value='CLI CONTAGEM']"

    recipient = B2bSetting::REMESSA_DEFAULT_RECIPIENT.merge('name' => 'Depósito B2B')
    patch b2c_transfer_settings_path, params: { b2b_setting: { b2c_to_b2b_issuer_company_id: @b2c.id, b2c_to_b2b_nature_id: @transfer.id,
                                                               b2c_to_b2b_remessa_issuer_company_id: @b2b.id, b2c_to_b2b_remessa_nature_id: @remessa.id,
                                                               b2c_to_b2b_remessa_recipient: recipient } }

    assert_redirected_to b2c_transfers_path
    setting = B2bSetting.current
    order = B2bOrder.new(kind: :b2c_transfer, transfer_direction: :b2c_to_b2b)
    assert_equal [@b2c, @transfer], [setting.issuer(order), setting.nature_for(order)]
    assert_equal [@b2b, @remessa], [setting.remessa_issuer(order), setting.remessa_nature_for(order)]
    assert_equal 'Depósito B2B', setting.remessa_recipient_data(order)['name']
    assert_equal 'CLI CONTAGEM', setting.remessa_recipient_data['name'], 'o abastecimento continua com o destinatário dele'
  end

  test 'the same company cannot be both branches' do
    patch b2c_transfer_settings_path, params: { b2b_setting: { b2c_to_b2b_issuer_company_id: @b2c.id, b2c_to_b2b_remessa_issuer_company_id: @b2c.id } }

    assert_response :unprocessable_entity
    assert_nil B2bSetting.current.b2c_to_b2b_issuer_company_id
  end

  test 'the list offers both directions and the new form keeps the chosen one' do
    build_order
    get b2c_transfers_path
    assert_select "a[href='#{new_b2c_transfer_path(direction: 'b2c_to_b2b')}']", text: /Nova B2C → B2B/
    assert_select "a[href='#{new_b2c_transfer_path}']", text: /Nova B2B → B2C/
    assert_select 'tbody .pg-tag', text: 'B2C → B2B'

    get new_b2c_transfer_path(direction: 'b2c_to_b2b')
    assert_select 'h1', /Nova Transferência B2C → B2B/
    assert_select "input[name='b2b_order[transfer_direction]'][value='b2c_to_b2b']"
    assert_select '#itemsTable[data-enforce-stock=true]'
    assert_match(/source=b2c_to_b2b/, response.body)
    assert_select '#b2cDestinationSection', count: 0
  end

  test 'creating reserves the B2C stock, not the Log02 one, and stays out of the approval queue' do
    post b2c_transfers_path, params: { b2b_order: { transfer_direction: 'b2c_to_b2b',
                                                    b2b_order_items_attributes: [{ sku: 'SKU1', name: 'Legging', quantity: 5, price: 10 }] } }

    order = B2bOrder.last
    assert order.b2c_to_b2b?
    assert_redirected_to b2c_transfers_path
    assert_match(/não vai ao Correios/, flash[:notice])
    assert_equal 'notes_only', order.log_stage
    assert_not_includes B2bOrder.honey_flow, order
    assert_not_includes B2bOrder.reserving_stock, order
    reservation = StockReservation.find_by!(tiny_order_id: order.reservation_key)
    assert_equal %w[b2c b2c_to_b2b], [reservation.account, reservation.source]
    assert_equal 5, reservation.quantity
  end

  test 'the Log02 never sends it to Correios, even if it is marked as approved' do
    order = build_order(status: :aprovado)

    HoneyB2bLog.stub(:create_in_correios, ->(_) { flunk 'não pode ir ao Correios' }) { HoneyB2bLog.create_pending! }

    assert_nil order.reload.correios_order_id
    assert_equal 0, Attempt.where(b2b_order_id: order.id).count
    post approve_honey_order_b2b_dashboard_index_path(id: order.id)
    assert_response :not_found
  end

  test 'the direction cannot change after the transfer is created' do
    order = build_order

    patch b2c_transfer_path(order), params: { b2b_order: { transfer_direction: 'b2b_to_b2c' } }

    assert order.reload.b2c_to_b2b?
  end

  test 'it emits the transfer note from B2C to B2B and the remessa from B2B; both in production make it faturado' do
    configure
    @b2c.update!(environment: :producao)
    @b2b.update!(environment: :producao)
    order = build_order

    get edit_b2c_transfer_path(order, tab: 'nota')
    assert_select '.it-fiscal-card:not(#remessaNote) .transfer-note__route', text: /Chase Filial B2B/
    assert_select '#remessaNote', text: /CLI CONTAGEM/

    emit(order, 'producao')
    transfer = FiscalNote.where(b2b_order: order).principal.last
    assert_equal @b2c, transfer.company
    assert_equal '5152', transfer.cfop_summary
    xml = Nokogiri::XML(transfer.xml.download).remove_namespaces!
    assert_equal '45723174000110', xml.at_xpath('//dest/CNPJ').text
    assert_equal '11222333000181', xml.at_xpath('//emit/CNPJ').text
    assert order.reload.aberto?, 'falta a remessa'

    emit(order, 'producao', 'remessa')
    remessa = FiscalNote.where(b2b_order: order).remessas.last
    assert_equal @b2b, remessa.company
    assert_equal '5905', remessa.cfop_summary
    assert_equal '34028316900520', Nokogiri::XML(remessa.xml.download).remove_namespaces!.at_xpath('//dest/CNPJ').text
    assert order.reload.faturado?
  end

  test 'homologation notes do not finish the transfer' do
    configure
    order = build_order

    emit(order, 'homologacao')
    emit(order, 'homologacao', 'remessa')

    assert_equal 2, FiscalNote.where(b2b_order: order).autorizada.count
    assert order.reload.aberto?
  end

  test 'the B2B to B2C direction keeps its fixed recipient and Log02 flow, and also has a remessa note' do
    order = build_order(transfer_direction: :b2b_to_b2c)

    assert_includes B2bOrder.honey_flow, order
    assert_equal 'review', order.log_stage
    assert order.remessa_note?
  end

  test 'the romaneio names the B2B branch' do
    configure
    order = build_order

    get romaneio_b2c_transfer_path(order)

    assert_response :success
    assert_match(/chase-filial-b2b/, response.headers['Content-Disposition'])
  end
end
