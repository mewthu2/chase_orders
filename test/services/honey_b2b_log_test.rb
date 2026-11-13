require 'test_helper'
require 'webmock/minitest'
require 'minitest/mock'
require_relative '../support/nfe_company_factory'

# Log02 dos pedidos feitos no Honey, sem o Tiny: criação no Correios, NF-e + XML e rastreio.
class HoneyB2bLogTest < ActiveSupport::TestCase
  include NfeCompanyFactory

  NS = { 'n' => 'http://www.portalfiscal.inf.br/nfe' }.freeze

  def setup
    ENV['TOKEN_TINY2_PRODUCTION'] = 'fake-token-tiny2'
    @user = User.create!(name: 'Log Honey', email: 'log_honey@example.com', password: 'password123')
    @client = Client.create!(responsible_name: 'Lojista', business_name: 'Loja Parceira Ltda', registration: '45.723.174/0001-10',
                             state_registration: '111222333', ie_indicator: 1, street: 'Rua B', number: '20', neighbourhood: 'Centro',
                             city: 'Belo Horizonte', state: 'MG', zip: '31000-000', city_ibge_code: '3106200', email: 'loja@example.com', phone: '31999998888')
    @location = TransferLocation.create!(name: 'Loja Centro', registration: '25.405.327/0004-17', street: 'Rua A', number: '10',
                                         neighbourhood: 'Centro', city: 'Belo Horizonte', state: 'MG', zip: '30000-000', city_ibge_code: '3106200')
    @carrier = Carrier.create!(name: 'MIX CARGO', registration: '34.028.316/0001-03', street: 'Rua T', number: '1',
                               neighbourhood: 'B', city: 'BH', state: 'MG', zip: '30000-000')
    Product.create!(sku: 'SKU1', shopify_product_name: 'Legging Apex Seamless', ncm: '61046200')
  end

  def order(kind = :sale, **attrs)
    base = case kind
           when :sale then { client: @client, payment_method: 'boleto', freight_service: 'SEDEX CORREIOS LOG+' }
           when :stock_transfer then { transfer_location: @location, price_list: :transfer, receiver_name: 'Maria Souza, Ana' }
           else { price_list: :transfer }
           end
    o = B2bOrder.new({ kind:, user: @user, status: :aprovado }.merge(base).merge(attrs))
    o.b2b_order_items.build(sku: 'SKU1', name: 'Legging', quantity: 2, price: 50)
    o.save!
    o
  end

  # Correios::Orders.create_orders de mentira: guarda o que seria enviado e responde "criado".
  def capture_creation
    sent = {}
    fake = lambda do |params, attempt, recipient_name: nil|
      sent.merge!(params:, recipient_name:)
      attempt.update!(status: :success, order_correios_id: 777)
    end
    Correios::Orders.stub(:create_orders, fake) { yield }
    sent
  end

  test 'a wholesale order by SEDEX is created in Correios with the client and the Honey number' do
    o = order
    sent = capture_creation { HoneyB2bLog.create_pending! }

    assert_equal format('1%08d', o.id), sent[:params][:invoice]
    assert_equal '39888', sent[:params][:forma_envio]
    assert_equal 'Loja Parceira Ltda', sent[:params][:nome]
    assert_equal '45723174000110', sent[:params][:cpf_cnpj]
    assert_equal [{ codigo: 'SKU1', quantidade: '2' }], sent[:params][:itens]
    assert_nil sent[:params][:cnpj_transportadora]
    o.reload
    assert_equal 777, o.correios_order_id
    assert o.preparando_envio?
    assert_equal 'invoice', o.log_stage
    assert Attempt.create_correios_order_honey.where(b2b_order_id: o.id).success.exists?
  end

  test 'by carrier the order goes as 74926 with the carrier CNPJ; a supply by hand goes SEDEX with mão própria to the receivers' do
    sale = order(:sale, freight_service: nil, carrier: @carrier)
    sent = capture_creation { HoneyB2bLog.create_in_correios(sale) }
    assert_equal '74926', sent[:params][:forma_envio]
    assert_equal '34028316000103', sent[:params][:cnpj_transportadora]

    supply = order(:stock_transfer)
    sent = capture_creation { HoneyB2bLog.create_in_correios(supply) }
    assert_equal '39888', sent[:params][:forma_envio]
    assert sent[:params][:mao_propria]
    assert_equal 'Maria Souza, Ana', sent[:recipient_name]

    b2c = order(:b2c_transfer)
    sent = capture_creation { HoneyB2bLog.create_in_correios(b2c) }
    assert_equal '74926', sent[:params][:forma_envio]
    assert_equal '25405327000336', sent[:params][:cnpj_transportadora]
    assert_equal B2bTinyService::B2C_TRANSFER_RECIPIENT_NAME, sent[:recipient_name]
  end

  test 'a pickup order goes to Correios as 74926 with the client as the carrier' do
    pickup = order(:sale, freight_service: nil, pickup: true)
    sent = capture_creation { HoneyB2bLog.create_in_correios(pickup) }
    assert_equal '74926', sent[:params][:forma_envio]
    assert_equal '45723174000110', sent[:params][:cnpj_transportadora]
    assert_nil sent[:params][:mao_propria]
  end

  test 'only approved, not ignored orders are created; a wholesale order without shipping fails with the reason' do
    pending = order(:sale, status: :aberto)
    ignored = order(:sale, log_ignored: true)
    sent = capture_creation { HoneyB2bLog.create_pending! }
    assert_empty sent
    assert_nil pending.reload.correios_order_id
    assert_nil ignored.reload.correios_order_id

    no_shipping = order(:sale, freight_service: nil)
    attempt = HoneyB2bLog.create_in_correios(no_shipping)
    assert attempt.error?
    assert_match(/forma de envio/, attempt.error)
  end

  test 'orders outside Correios reserve the Log02 stock; once created or ignored the reservation goes away' do
    o = order(:sale, status: :aberto)
    HoneyB2bLog.sync_reservations!
    assert_equal 2, StockReservation.reserved_for('SKU1', account: :b2b)
    assert_equal 0, StockReservation.reserved_for('SKU1', account: :b2b, exclude_tiny_order_id: o.reservation_key)

    o.update_columns(log_ignored: true)
    HoneyB2bLog.sync_reservations!
    assert_equal 0, StockReservation.reserved_for('SKU1', account: :b2b)
  end

  test 'the XML step emits the production NF-e in Honey (payment, installments and freight) and sends it to Correios' do
    company = create_nfe_company(environment: :producao)
    nature = create_sale_nature(company, description: 'Atacado', default_for_kind: false)
    B2bSetting.current.update!(issuer_company: company, sale_nature: nature)
    o = order(:sale, payment_method: 'boleto', payment_terms: '30 60', freight_value: 20, correios_order_id: 777, status: :preparando_envio)

    authorize = ->(note, **) { note.update!(status: :autorizada); note }
    sent_xml = nil
    send = ->(attempt) { sent_xml = attempt.xml_nota; attempt.update!(status: :error, status_code: '200', message: 'Rastreio não disponível') }
    Nfe::Transmitter.stub(:call, authorize) do
      Correios::Invoices.stub(:send_xml_to_correios, send) { HoneyB2bLog.send_pending_xml! }
    end

    note = FiscalNote.find_by(b2b_order_id: o.id)
    assert note.producao?
    assert note.autorizada?
    xml = Nokogiri::XML(sent_xml)
    assert_equal '15', xml.at_xpath('//n:pag/n:detPag/n:tPag', NS).text
    assert_equal %w[001 002], xml.xpath('//n:cobr/n:dup/n:nDup', NS).map(&:text)
    assert_equal BigDecimal('120.00'), xml.xpath('//n:cobr/n:dup/n:vDup', NS).sum { |n| BigDecimal(n.text) }
    assert_equal BigDecimal('20.00'), BigDecimal(xml.at_xpath('//n:ICMSTot/n:vFrete', NS).text)
    assert_equal BigDecimal('120.00'), BigDecimal(xml.at_xpath('//n:ICMSTot/n:vNF', NS).text)
    o.reload
    assert o.faturado?
    assert o.xml_sent_at
    assert_equal 'tracking', o.log_stage
  end

  test 'a company still in homologação does not send a test note to Correios' do
    company = create_nfe_company(environment: :homologacao)
    B2bSetting.current.update!(issuer_company: company, sale_nature: create_sale_nature(company))
    o = order(:sale, correios_order_id: 777, status: :preparando_envio)

    attempt = Correios::Invoices.stub(:send_xml_to_correios, ->(*) { flunk 'não pode mandar ao Correios' }) { HoneyB2bLog.send_xml(o) }

    assert attempt.error?
    assert_match(/homologação/, attempt.error)
    assert_nil o.reload.xml_sent_at
  end

  test 'the tracking code lands on the order' do
    o = order(:sale, correios_order_id: 777, xml_sent_at: Time.current, status: :faturado)
    Correios::Orders.stub(:get_tracking, ->(*, **) { { 'rastreio' => [{ 'codigoObjeto' => 'AB123456789BR' }] } }) { HoneyB2bLog.track_pending! }

    o.reload
    assert_equal 'AB123456789BR', o.tracking_code
    assert o.enviado?
    assert_equal 'shipped', o.log_stage
  end
end
