require 'test_helper'
require 'webmock/minitest'
require 'minitest/mock'

# O abastecimento sai do "Enviar ao Tiny" com a nota emitida, e o DANFE fica para baixar na lista.
class StockTransferInvoiceTest < ActionDispatch::IntegrationTest
  PEDIDO_URL = 'https://api.tiny.com.br/api2/pedido.incluir.php'.freeze
  INVOICE_URL = 'https://api.tiny.com.br/api2/gerar.nota.fiscal.pedido.php'.freeze
  EMIT_URL = 'https://api.tiny.com.br/api2/nota.fiscal.emitir.php'.freeze
  ORDER_URL = 'https://api.tiny.com.br/api2/pedido.obter.php'.freeze
  OBTAIN_URL = 'https://api.tiny.com.br/api2/nota.fiscal.obter.php'.freeze
  LINK_URL = 'https://api.tiny.com.br/api2/nota.fiscal.obter.link.php'.freeze
  DANFE_URL = 'https://erp.olist.com/doc.view?id=abc'.freeze

  def setup
    ENV['TOKEN_TINY2_PRODUCTION'] = 'fake-token-tiny2'
    ENV['OBTER_NOTA_FISCAL'] = OBTAIN_URL
    ENV['SMTP_ADDRESS'] = 'smtp.example.com'
    @admin = User.create!(name: 'Admin Danfe', email: 'admin_danfe@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @location = TransferLocation.create!(
      name: 'Loja Danfe', registration: '25.405.327/0001-74', street: 'Rua A',
      number: '10', neighbourhood: 'Bairro', city: 'BH', state: 'MG', zip: '30000-000'
    )
    sign_in @admin
  end

  def teardown
    ENV.delete('SMTP_ADDRESS')
  end

  def build_transfer(**attrs)
    order = B2bOrder.new({ kind: :stock_transfer, user: @admin, transfer_location: @location, price_list: :transfer, receiver_name: 'Maria' }.merge(attrs))
    order.b2b_order_items.build(sku: 'SKU1', quantity: 1, price: 1)
    order.save!
    order
  end

  def stub_send_to_tiny
    stub_request(:post, PEDIDO_URL).to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '90000777', numero: '777' } } } }.to_json)
    stub_request(:post, INVOICE_URL).to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '5', numero: '42' } } } }.to_json)
  end

  def stub_emit(retorno)
    stub_request(:post, EMIT_URL).with(body: hash_including('id' => '5')).to_return(body: { retorno: retorno }.to_json)
  end

  def stub_invoice(situacao, descricao)
    stub_request(:get, ORDER_URL).with(query: hash_including('id' => '90000777'))
                                 .to_return(body: { retorno: { status: 'OK', pedido: { id: '90000777', id_nota_fiscal: '5' } } }.to_json)
    stub_request(:get, OBTAIN_URL).with(query: hash_including('id' => '5'))
                                  .to_return(body: { retorno: { status: 'OK', nota_fiscal: { numero: '042', situacao: situacao, descricao_situacao: descricao } } }.to_json)
  end

  test 'sending a stock transfer to Tiny generates and emits its invoice' do
    stub_send_to_tiny
    emit = stub_emit(status: 'OK', status_processamento: '3')

    post transmit_stock_transfer_path(build_transfer)

    assert_requested emit
    assert_redirected_to stock_transfers_path
    assert_match(/Nota fiscal \(nº 42\) emitida no Tiny/, flash[:notice])
  end

  test 'when Tiny does not emit the invoice the user is told to emit it there' do
    stub_send_to_tiny
    stub_emit(status: 'Erro', status_processamento: '2', erros: [{ erro: 'Rejeição: IE do destinatário inválida' }])

    post transmit_stock_transfer_path(build_transfer)

    assert_match(/gerada, mas o Tiny não emitiu: Rejeição: IE do destinatário inválida/, flash[:alert])
  end

  test 'the list shows the DANFE button only for transfers already sent to Tiny' do
    sent = build_transfer(tiny_reference_id: '90000777', tiny_reference_number: '777')
    pending = build_transfer

    get stock_transfers_path

    assert_select "a[href='#{danfe_stock_transfer_path(sent)}']", count: 1
    assert_select "a[href='#{danfe_stock_transfer_path(pending)}']", count: 0
  end

  test 'the DANFE of an authorized invoice is downloaded as a PDF' do
    order = build_transfer(tiny_reference_id: '90000777', tiny_reference_number: '777')
    stub_invoice('6', 'Autorizada')
    stub_request(:post, LINK_URL).with(body: hash_including('id' => '5'))
                                 .to_return(body: { retorno: { status: 'OK', link_nfe: DANFE_URL } }.to_json)
    converted = []
    converter = Object.new
    converter.define_singleton_method(:pdf_from_url) { |url, **options| converted << [url, options] && '%PDF-fake' }

    WickedPdf.stub(:new, converter) { get danfe_stock_transfer_path(order) }

    assert_equal [[DANFE_URL, { page_size: 'A4' }]], converted
    assert_response :success
    assert_equal 'application/pdf', response.media_type
    assert_match(/DANFE-042\.pdf/, response.headers['Content-Disposition'])
    assert_equal '%PDF-fake', response.body
  end

  test 'an invoice not yet authorized has no DANFE' do
    order = build_transfer(tiny_reference_id: '90000777', tiny_reference_number: '777')
    stub_invoice('1', 'Pendente')

    get danfe_stock_transfer_path(order)

    assert_redirected_to stock_transfers_path
    assert_match(/ainda não foi autorizada \(situação no Tiny: Pendente\)/, flash[:alert])
  end

  test 'without an SMTP configured there is only the download button, and sending is refused' do
    ENV.delete('SMTP_ADDRESS')
    sent = build_transfer(tiny_reference_id: '90000777', tiny_reference_number: '777')

    get stock_transfers_path

    assert_select "a[href='#{danfe_stock_transfer_path(sent)}']", count: 1
    assert_select "button[data-send-url]", count: 0
    assert_select '#sendDanfeModal', count: 0

    assert_no_enqueued_emails { post send_danfe_stock_transfer_path(sent), params: { emails: 'loja@chase.com.br' } }
    assert_equal 'O envio de e-mail ainda não está configurado.', flash[:alert]
  end

  def stub_danfe_link
    stub_invoice('6', 'Autorizada')
    stub_request(:post, LINK_URL).with(body: hash_including('id' => '5'))
                                 .to_return(body: { retorno: { status: 'OK', link_nfe: DANFE_URL } }.to_json)
  end

  test 'the list has a send-by-email button for transfers already sent to Tiny' do
    sent = build_transfer(tiny_reference_id: '90000777', tiny_reference_number: '777')

    get stock_transfers_path

    assert_select "button[data-send-url='#{send_danfe_stock_transfer_path(sent)}']", count: 1
    assert_select '#sendDanfeModal input[name=emails]'
  end

  test 'sending the invoice queues an e-mail with the DANFE to every address typed' do
    order = build_transfer(tiny_reference_id: '90000777', tiny_reference_number: '777')
    stub_danfe_link

    assert_enqueued_emails 1 do
      post send_danfe_stock_transfer_path(order), params: { emails: 'loja@chase.com.br, gerente@chase.com.br' }
    end

    assert_redirected_to stock_transfers_path
    assert_equal 'Nota nº 042 sendo enviada para loja@chase.com.br, gerente@chase.com.br.', flash[:notice]
  end

  test 'an invalid e-mail is refused before asking Tiny' do
    order = build_transfer(tiny_reference_id: '90000777', tiny_reference_number: '777')

    assert_no_enqueued_emails do
      post send_danfe_stock_transfer_path(order), params: { emails: 'loja@chase.com.br, nao-e-email' }
    end

    assert_match(/Informe e-mail\(s\) válido\(s\).*nao-e-email/, flash[:alert])
    assert_not_requested :get, ORDER_URL
  end

  test 'an invoice not yet authorized is not sent' do
    order = build_transfer(tiny_reference_id: '90000777', tiny_reference_number: '777')
    stub_invoice('1', 'Pendente')

    assert_no_enqueued_emails do
      post send_danfe_stock_transfer_path(order), params: { emails: 'loja@chase.com.br' }
    end

    assert_match(/não enviada: A nota ainda não foi autorizada/, flash[:alert])
  end

  test 'the e-mail carries the DANFE as a PDF attachment and the transfer details' do
    order = build_transfer(tiny_reference_id: '90000777', tiny_reference_number: '777')
    converter = Object.new
    converter.define_singleton_method(:pdf_from_url) { |_url, **_options| '%PDF-fake' }

    mail = WickedPdf.stub(:new, converter) do
      InvoiceMailer.with(order_id: order.id, to: ['loja@chase.com.br'], danfe_url: DANFE_URL, number: '042',
                         sender_name: 'Admin Danfe').stock_transfer_danfe.tap(&:deliver_now)
    end

    assert_equal ['loja@chase.com.br'], mail.to
    assert_equal '📦 Nota fiscal nº 042 · Abastecimento Loja Danfe', mail.subject
    pdf = mail.attachments['DANFE-042.pdf']
    assert_equal 'application/pdf', pdf.mime_type
    assert_equal '%PDF-fake', pdf.body.decoded
    assert_includes mail.html_part.body.decoded, 'Maria'
    assert_includes mail.text_part.body.decoded, 'SKU1'
  end
end
