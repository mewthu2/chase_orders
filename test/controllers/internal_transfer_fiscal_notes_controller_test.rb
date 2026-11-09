require 'test_helper'
require 'minitest/mock'
require_relative '../support/nfe_company_factory'

# Aba "Nota fiscal" da edição da Transferência Interna: uma nota de homologação e uma de produção por remessa.
class InternalTransferFiscalNotesControllerTest < ActionDispatch::IntegrationTest
  include NfeCompanyFactory

  AUTHORIZE = ->(note, **) { note.update!(status: :autorizada, protocol: '131000000000001', authorized_at: Time.current); note }

  def setup
    @admin = User.create!(name: 'Admin', email: 'admin_itfn@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @lagoa = Location.create!(slug: 'lagoa_seca', name: 'Lagoa Seca', shopify_location_id: '111')
    @bh = Location.create!(slug: 'bh_shopping', name: 'BH Shopping', shopify_location_id: '222')
    @product = Product.create!(sku: 'SKU-A', shopify_product_name: 'Camiseta', shopify_inventory_item_id: '9001', ncm: '61091000', cost: '20.00', price: '99.90')
    @bh.update!(company: create_nfe_company(environment: :homologacao, next_nfe_number: 500, next_nfe_number_homologation: 7))
    @lagoa.update!(company: create_nfe_company(legal_name: 'Chase Lagoa Ltda', cnpj: '45.723.174/0001-10', state_registration: '87654321'))
    [@bh, @lagoa].each do |location|
      location.company.operation_natures.create!(description: 'Transferência de mercadoria', kind: :transfer, cfop: '?152',
                                                 final_consumer: false, icms_situation: '41', pis_cst: '49', cofins_cst: '49')
    end
    transfer = InternalTransfer.new(destination_location: @lagoa, requested_by: @admin, approval_status: :aprovada)
    @shipment = transfer.shipments.build(origin_location: @bh)
    @shipment.items.build(product: @product, quantity: 2)
    transfer.save!
    @transfer = transfer
    sign_in @admin
  end

  def issue(env, transmit: AUTHORIZE)
    Nfe::Transmitter.stub(:call, transmit) do
      post internal_transfer_shipment_fiscal_notes_path(@transfer, @shipment), params: { environment: env }
    end
    @shipment.fiscal_notes.where(environment: env).order(:id).last
  end

  test 'the edit page has the Pedido and Nota fiscal tabs' do
    get edit_internal_transfer_path(@transfer, tab: 'nota')

    assert_response :success
    assert_select '.it-tabs [data-it-tab="pedido"]', text: /Pedido/
    assert_select '.it-tabs [data-it-tab="nota"].is-active', text: /Nota fiscal/
    assert_select '[data-it-panel="nota"]:not([hidden]) .it-slot--homologacao', text: /Emitir nota de homologação/
    assert_select '[data-it-panel="nota"] .it-slot--producao', text: /Emitir nota de produção.*nº 500/m
    assert_select '[data-it-panel="pedido"][hidden] form#internalTransferForm'
  end

  test 'issues one homologation and one production note per shipment, each with its own numbering' do
    homolog = issue('homologacao')
    assert_redirected_to edit_internal_transfer_path(@transfer, tab: 'nota')
    assert homolog.autorizada?
    assert_equal 7, homolog.number
    assert_match(/<tpAmb>2<\/tpAmb>/, homolog.xml.download)

    production = issue('producao')
    assert production.producao?
    assert_equal 500, production.number
    assert_match(/<tpAmb>1<\/tpAmb>/, production.xml.download)
    assert_equal [8, 501], @bh.company.reload.values_at(:next_nfe_number_homologation, :next_nfe_number)

    issue('homologacao')
    assert_match(/Já existe nota fiscal de homologação ativa/, flash[:alert])
    assert_equal 2, @shipment.fiscal_notes.count

    follow_redirect!
    assert_select '.it-slot--producao.is-ok', text: /Autorizada.*nº 500/m
    assert_select '.it-tabs [data-it-tab="nota"] .count', text: '2'
  end

  test 'the item goes on the transfer note at 80% of the sale price' do
    note = issue('homologacao')

    assert_match(%r{<vUnCom>79.9200</vUnCom>}, note.xml.download)
    assert_equal BigDecimal('159.84'), note.total_value
  end

  test 'a homologation note can be deleted and issued again' do
    note = issue('homologacao')

    delete internal_transfer_shipment_fiscal_note_path(@transfer, @shipment, note)

    assert_match(/excluída/, flash[:notice])
    refute FiscalNote.exists?(note.id)
    assert_equal 'fiscal_note_deleted', @transfer.events.recent.first.action
    assert issue('homologacao').autorizada?
  end

  test 'an authorized production note cannot be deleted (it needs a cancellation at SEFAZ)' do
    note = issue('producao')

    delete internal_transfer_shipment_fiscal_note_path(@transfer, @shipment, note)

    assert FiscalNote.exists?(note.id)
    assert_match(/precisa ser cancelada/, flash[:alert])
  end

  test 'deleting a rejected production note gives the number back when it was the last one' do
    reject = ->(note, **) { note.update!(status: :rejeitada, sefaz_status_code: '225', error_message: 'Rejeição 225'); note }
    note = issue('producao', transmit: reject)
    assert_equal 501, @bh.company.reload.next_nfe_number

    delete internal_transfer_shipment_fiscal_note_path(@transfer, @shipment, note)

    assert_equal 500, @bh.company.reload.next_nfe_number
  end

  test 'changing the items is refused while the shipments have notes' do
    issue('homologacao')

    patch internal_transfer_path(@transfer), params: { internal_transfer: {
      destination_location_id: @lagoa.id, items: { '0' => { product_id: @product.id, location_id: @bh.id, quantity: 5 } }
    } }

    assert_response :unprocessable_entity
    assert_match(/Exclua as notas na aba Nota fiscal/, response.body)
    assert_equal 2, @shipment.items.reload.sum(&:quantity)
  end

  test 'the transfers list shows the notes of each transfer' do
    issue('homologacao')

    get internal_transfers_path

    assert_select "a.it-pill.is-ok.it-pill--homologacao[href='#{edit_internal_transfer_path(@transfer, tab: 'nota')}']", text: /nº 7.*Homolog/m
  end

  test 'stores of the same company have no transfer note' do
    @lagoa.update_column(:company_id, @bh.company_id)

    get edit_internal_transfer_path(@transfer, tab: 'nota')

    assert_select '.it-fiscal-card .callout.is-warn', text: /mesma empresa/
    assert_select '.it-slot', count: 0
  end
end
