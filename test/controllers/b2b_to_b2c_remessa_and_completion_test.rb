require 'test_helper'
require 'minitest/mock'
require_relative '../support/nfe_company_factory'

# Transferência B2B → B2C: nota de remessa da filial B2C para o depósito do Correios (como no abastecimento e no
# B2C → B2B), o número de cada nota ao lado do N na lista e o Concluir para fechar a transferência à mão.
class B2bToB2cRemessaAndCompletionTest < ActionDispatch::IntegrationTest
  include NfeCompanyFactory

  def setup
    @admin = User.create!(name: 'Admin B2B B2C', email: 'admin_b2b_b2c_rem@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @b2c = create_nfe_company(legal_name: 'Chase Filial B2C', cnpj: '11.222.333/0001-81')
    @remessa = @b2c.operation_natures.create!(description: 'Remessa para depósito', kind: :other, cfop: '?905',
                                              final_consumer: false, icms_situation: '41', pis_cst: '08', cofins_cst: '08')
    Product.create!(sku: 'SKU1', shopify_product_name: 'Legging', ncm: '61046300')
    sign_in @admin
  end

  def build_order(**attrs)
    order = B2bOrder.new({ kind: :b2c_transfer, transfer_direction: :b2b_to_b2c, user: @admin, price_list: :transfer }.merge(attrs))
    order.b2b_order_items.build(sku: 'SKU1', name: 'Legging', quantity: 2, price: 10)
    order.save!
    order
  end

  test 'the settings save the B2B to B2C remessa company, nature and recipient, apart from the other remessas' do
    get b2c_transfer_settings_path
    assert_select "#b2bToB2cRemessaSettings select[name='b2b_setting[b2b_to_b2c_remessa_issuer_company_id]']"
    assert_select "#b2bToB2cRemessaSettings input[name='b2b_setting[b2b_to_b2c_remessa_recipient][name]'][value='CLI CONTAGEM']"

    recipient = B2bSetting::REMESSA_DEFAULT_RECIPIENT.merge('complement' => 'Docas B2C')
    patch b2c_transfer_settings_path, params: { b2b_setting: { b2b_to_b2c_remessa_issuer_company_id: @b2c.id, b2b_to_b2c_remessa_nature_id: @remessa.id,
                                                               b2b_to_b2c_remessa_recipient: recipient } }

    assert_redirected_to b2c_transfers_path
    setting = B2bSetting.current
    order = build_order
    assert_equal [@b2c, @remessa], [setting.remessa_issuer(order), setting.remessa_nature_for(order)]
    assert_equal 'Docas B2C', setting.remessa_recipient_data(order)['complement']
    assert_not_equal 'Docas B2C', setting.remessa_recipient_data(B2bOrder.new(kind: :b2c_transfer, transfer_direction: :b2c_to_b2b))['complement']
    assert_not_equal 'Docas B2C', setting.remessa_recipient_data(B2bOrder.new(kind: :stock_transfer))['complement']
  end

  test 'without a choice, the B2B to B2C remessa comes from the B2C branch (the one that receives the transfer)' do
    setting = B2bSetting.current
    setting.update!(b2c_to_b2b_issuer_company: @b2c)

    assert_equal @b2c, setting.remessa_issuer(build_order)
    assert_nil setting.b2b_to_b2c_remessa_issuer_company
  end

  test 'the Nota fiscal tab has the remessa card and emits it from the B2C branch to the Correios depot' do
    B2bSetting.current.update!(b2b_to_b2c_remessa_issuer_company: @b2c, b2b_to_b2c_remessa_nature: @remessa)
    order = build_order

    get edit_b2c_transfer_path(order, tab: 'nota')
    assert_select '#remessaNote', text: /CLI CONTAGEM/

    Nfe::Transmitter.stub(:call, ->(note, **) { note.update!(status: :autorizada, protocol: '1') }) do
      post b2b_order_fiscal_notes_path(b2b_order_id: order.id), params: { environment: 'homologacao', role: 'remessa' }
    end

    remessa = FiscalNote.where(b2b_order: order).remessas.last
    assert_equal @b2c, remessa.company
    assert_equal '5905', remessa.cfop_summary
    assert_equal '90', remessa.payment_method
    assert_equal '34028316900520', Nokogiri::XML(remessa.xml.download).remove_namespaces!.at_xpath('//dest/CNPJ').text
    assert_empty FiscalNote.where(b2b_order: order).principal, 'a nota de transferência continua separada'
  end

  test 'the list shows the number of each note inside its N, with a second N.r for the remessa' do
    order = build_order(status: :faturado)
    FiscalNote.create!(company: @b2c, b2b_order: order, number: 1324, series: 1, environment: :producao, status: :autorizada)
    FiscalNote.create!(company: @b2c, b2b_order: order, number: 1325, series: 1, environment: :producao, status: :assinada, role: 'remessa')
    pending_remessa = build_order

    get b2c_transfers_path

    assert_select 'a.pg-pn.pg-pn--wide.is-ok', text: /\AN\s*1324\z/
    assert_select "a.pg-pn--remessa.is-wait[href='#{edit_b2c_transfer_path(order, tab: 'nota', anchor: 'remessaNote')}'][data-tip*='Nota de remessa: NF-e nº 1325']", text: /\AN\.r\s*1325\z/
    assert_select "a.pg-pn--remessa.is-none[href='#{edit_b2c_transfer_path(pending_remessa, tab: 'nota', anchor: 'remessaNote')}']", text: 'N.r'
  end

  test 'Concluir finishes a billed B2B to B2C transfer and takes it out of the Log02 queues' do
    order = build_order(status: :faturado, correios_order_id: '100000001', xml_sent_at: 1.hour.ago)
    assert_includes B2bOrder.waiting_tracking, order

    get b2c_transfers_path
    assert_select "form[action='#{complete_b2c_transfer_path(order)}']"

    post complete_b2c_transfer_path(order)

    assert_redirected_to b2c_transfers_path
    order.reload
    assert order.enviado?
    assert order.log_ignored?
    assert_equal 'completed', order.log_stage
    assert_not_includes B2bOrder.waiting_tracking, order
    follow_redirect!
    assert_select 'tbody .ticket-status', text: 'Concluída'
  end

  test 'Concluir is not offered nor accepted before the note, nor in the B2C to B2B direction' do
    waiting = build_order(status: :aprovado)
    other_way = build_order(transfer_direction: :b2c_to_b2b, status: :faturado)

    get b2c_transfers_path
    assert_select "form[action='#{complete_b2c_transfer_path(waiting)}']", count: 0
    assert_select "form[action='#{complete_b2c_transfer_path(other_way)}']", count: 0

    post complete_b2c_transfer_path(waiting)
    assert_match(/não pode ser concluída/, flash[:alert])
    assert waiting.reload.aprovado?
  end

  test 'an old B2B to B2C transfer from Tiny, stuck in preparing, can be finished' do
    order = build_order(tiny_reference_id: '902371809', status: :preparando_envio)

    post complete_b2c_transfer_path(order)

    assert order.reload.enviado?
  end

  test 'a profile that only views transfers cannot finish them' do
    order = build_order(status: :faturado)
    profile = Profile.create!(name: 'Só vê transferências')
    profile.screen_permissions.create!(screen_key: 'b2b_transfers', actions: 'V')
    viewer = User.create!(name: 'Leitor', email: 'leitor_b2c@example.com', password: 'password123')
    viewer.profiles << profile
    sign_in viewer

    post complete_b2c_transfer_path(order)

    assert order.reload.faturado?
  end
end
