require 'test_helper'
require_relative '../support/nfe_company_factory'

# Aba Nota fiscal do pedido B2B (letra N na lista da transferência B2C): informações complementares e
# transportadora, editáveis até a nota de produção ser autorizada.
class B2bOrderNoteDetailsTest < ActionDispatch::IntegrationTest
  include NfeCompanyFactory

  def setup
    @admin = User.create!(name: 'Admin', email: 'admin_nfd@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @carrier = Carrier.create!(name: 'Mix Cargo', registration: '13.642.117/0001-10', street: 'Rua A', number: '1',
                               neighbourhood: 'Centro', city: 'Belo Horizonte', state: 'MG', zip: '30000-000')
    @order = B2bOrder.new(kind: :b2c_transfer, user: @admin, price_list: :transfer)
    @order.b2b_order_items.build(sku: 'SKU1', quantity: 1, price: 1)
    @order.save!
    @company = create_nfe_company
    sign_in @admin
  end

  def save_details(**attrs)
    patch details_b2b_order_fiscal_notes_path(b2b_order_id: @order.id), params: { b2b_order: attrs }
  end

  test 'the Nota fiscal tab shows the editable note details' do
    get edit_b2c_transfer_path(@order, tab: 'nota')

    assert_response :success
    assert_select "form[action='#{details_b2b_order_fiscal_notes_path(b2b_order_id: @order.id)}'] fieldset:not([disabled])"
    assert_select "select[name='b2b_order[nf_carrier_id]'] option[value='#{@carrier.id}']"
    assert_select "textarea[name='b2b_order[nf_additional_info]']"
  end

  test 'saves the carrier, the freight mode and the additional info; blank goes back to the nature text' do
    save_details(nf_carrier_id: @carrier.id, nf_freight_mode: '0', nf_additional_info: '  Transferência para a filial B2C  ')

    assert_redirected_to edit_b2c_transfer_path(@order, tab: 'nota')
    @order.reload
    assert_equal [@carrier, '0', 'Transferência para a filial B2C'], [@order.nf_carrier, @order.nf_freight_mode, @order.nf_additional_info]

    save_details(nf_carrier_id: '', nf_freight_mode: '', nf_additional_info: '')
    @order.reload
    assert_nil @order.nf_carrier_id
    assert_nil @order.nf_freight_mode
    assert_nil @order.nf_additional_info
  end

  test 'an invalid freight mode is refused' do
    save_details(nf_freight_mode: '7')

    assert_nil @order.reload.nf_freight_mode
    assert_match(/Nf freight mode|modalidade|freight/i, flash[:alert])
  end

  test 'an authorized production note locks the details; a rejected one lets them change' do
    note = FiscalNote.create!(company: @company, b2b_order: @order, number: 5, series: 1, environment: :producao, status: :autorizada)

    save_details(nf_additional_info: 'novo texto')
    assert_nil @order.reload.nf_additional_info
    assert_match(/nº 5 está autorizada/, flash[:alert])
    get edit_b2c_transfer_path(@order, tab: 'nota')
    assert_select 'form.nf-details__form fieldset[disabled]'

    note.update!(status: :rejeitada)
    save_details(nf_additional_info: 'novo texto')
    assert_equal 'novo texto', @order.reload.nf_additional_info
  end

  test 'the tab shows the note that is valid, not a canceled one created later; the canceled ones go to the history' do
    valid = FiscalNote.create!(company: @company, b2b_order: @order, number: 15_790, series: 1, status: :autorizada, environment: :producao)
    canceled = FiscalNote.create!(company: @company, b2b_order: @order, number: 15_791, series: 1, status: :cancelada, environment: :producao,
                                  created_at: valid.created_at)

    get edit_b2c_transfer_path(@order, tab: 'nota')

    assert_select '.it-fiscal-slots', text: /15790/
    assert_select '.it-fiscal-slots', text: /15791/, count: 0
    assert_select '.it-fiscal-history a[href=?]', fiscal_note_path(canceled), text: /15791/
  end
end
