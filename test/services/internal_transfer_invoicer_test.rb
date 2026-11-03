require 'test_helper'
require 'minitest/mock'
require_relative '../support/nfe_company_factory'
require_relative '../support/nfe_schema'

class InternalTransferInvoicerTest < ActiveSupport::TestCase
  include NfeCompanyFactory
  NS = { 'n' => 'http://www.portalfiscal.inf.br/nfe' }.freeze

  def setup
    @origin_company = create_nfe_company
    @destination_company = create_nfe_company(legal_name: 'Chase Rio Comercio Ltda', cnpj: '45.723.174/0001-10', state_registration: '87654321',
                                              street: 'Av. das Américas', number: '4666', neighbourhood: 'Barra da Tijuca', city: 'Rio de Janeiro',
                                              city_ibge_code: '3304557', state: 'RJ', zip: '22640-102')
    @bh = Location.create!(slug: 'bh_shopping', name: 'BH Shopping', shopify_location_id: '222', company: @origin_company)
    @rj = Location.create!(slug: 'rj', name: 'Barra Shopping', shopify_location_id: '333', company: @destination_company)
    @requester = User.create!(name: 'Solicitante', email: 'solicitante_inv@example.com', password: 'password123')
    @product = Product.create!(sku: 'SKU-A', shopify_product_name: 'Camiseta', shopify_inventory_item_id: '9001', ncm: '61091000', cost: '35.50', price: '129.90')
  end

  def build_shipment(origin: @bh, destination: @rj, quantity: 3)
    transfer = InternalTransfer.new(destination_location: destination, requested_by: @requester, approval_status: :aprovada)
    shipment = transfer.shipments.build(origin_location: origin)
    shipment.items.build(product: @product, quantity: quantity)
    transfer.save!
    shipment.update!(status: :reservado)
    shipment.items.each { |item| item.update!(status: :reserved) }
    shipment.reload
  end

  def authorize = ->(note, **) { note.update!(status: :autorizada, protocol: '131000000000001'); note }

  test 'emits the transfer note from the origin store company to the destination store company, at cost' do
    shipment = build_shipment
    note = Nfe::Transmitter.stub(:call, authorize) { InternalTransferInvoicer.call(shipment) }

    assert note.autorizada?
    assert_equal shipment, note.internal_transfer_shipment
    assert_equal @origin_company, note.company
    assert_equal 'Transferência de mercadoria', note.operation_nature
    assert_equal '6152', note.cfop_summary, 'MG → RJ usa o CFOP de transferência para outro estado'
    assert_equal BigDecimal('106.50'), note.total_value

    xml = note.xml.download
    assert_equal [], NfeSchema.errors(xml)
    doc = Nokogiri::XML(xml)
    assert_equal '45723174000110', doc.at_xpath('//n:dest/n:CNPJ', NS).text
    assert_equal '0', doc.at_xpath('//n:ide/n:indFinal', NS).text
    assert_match(/Transferência interna nº #{shipment.internal_transfer_id}: de BH Shopping para Barra Shopping/, doc.at_xpath('//n:infCpl', NS).text)
  end

  test 'uses the default transfer nature of the company when there is one' do
    @origin_company.operation_natures.create!(description: 'Transferência entre filiais', kind: :transfer, default_for_kind: true, cfop: '?152',
                                              final_consumer: true, icms_situation: '41', pis_cst: '49', cofins_cst: '49')
    note = Nfe::Transmitter.stub(:call, authorize) { InternalTransferInvoicer.call(build_shipment) }

    assert_equal 'Transferência entre filiais', note.operation_nature
    assert_equal '6152', note.cfop_summary
    assert_equal '0', Nokogiri::XML(note.xml.download).at_xpath('//n:ide/n:indFinal', NS).text, 'transferência nunca é para consumidor final'
  end

  test 'stores of the same company need no note' do
    @rj.update_column(:company_id, @origin_company.id) # o cadastro não deixa (uma loja por empresa), mas o envio não quebra

    assert_nil InternalTransferInvoicer.call(build_shipment)
    assert_equal 0, FiscalNote.count
  end

  test 'a store without a company blocks the shipment' do
    @rj.update!(company: nil)

    error = assert_raises(InternalTransferInvoicer::Error) { InternalTransferInvoicer.call(build_shipment) }
    assert_match(/Barra Shopping ainda não está ligada a uma empresa/, error.message)
  end

  test 'a rejected note is replaced by a new one with the same number on the next try' do
    shipment = build_shipment
    reject = ->(note, **) { note.update!(status: :rejeitada, sefaz_status_code: '539', error_message: 'Rejeição 539: duplicidade'); note }
    first = Nfe::Transmitter.stub(:call, reject) { InternalTransferInvoicer.call(shipment) }
    assert first.rejeitada?

    second = Nfe::Transmitter.stub(:call, authorize) { InternalTransferInvoicer.call(shipment) }

    assert second.autorizada?
    assert_equal first.number, second.number
    assert_equal 1, shipment.fiscal_notes.count
  end

  test 'a note left without a SEFAZ answer is consulted instead of emitting another one' do
    shipment = build_shipment
    fail_comm = ->(note, **) { note.update!(status: :erro, error_message: 'timeout'); note }
    first = Nfe::Transmitter.stub(:call, fail_comm) { InternalTransferInvoicer.call(shipment) }

    calls = []
    consult = ->(note, **opts) { calls << opts; note.update!(status: :autorizada); note }
    second = Nfe::Transmitter.stub(:call, consult) { InternalTransferInvoicer.call(shipment) }

    assert_equal first, second
    assert second.autorizada?
    assert_equal [{ consult: true }], calls
  end

  test 'missing fiscal data is reported before anything is sent' do
    @product.update!(ncm: nil, cost: nil, price: nil)

    error = assert_raises(InternalTransferInvoicer::Error) { InternalTransferInvoicer.call(build_shipment) }
    assert_match(/NCM do SKU SKU-A/, error.message)
    assert_match(/custo ou preço do SKU SKU-A/, error.message)
    assert_equal 0, FiscalNote.count
  end
end
