# Envio da nota fiscal (DANFE em PDF) de um abastecimento de loja para o e-mail informado na lista.
# O link do DANFE já vem conferido pelo controller (nota autorizada); a conversão em PDF roda aqui,
# no worker, para a tela não esperar o wkhtmltopdf.
class InvoiceMailer < ApplicationMailer
  layout false

  LOGO_PATH = TicketMailer::LOGO_PATH

  # O envio da nota só aparece com um SMTP de verdade configurado (SMTP_ADDRESS): sem domínio próprio,
  # o Mailtrap é só sandbox e os e-mails não chegariam às lojas.
  def self.enabled?
    ENV['SMTP_ADDRESS'].present?
  end

  def stock_transfer_danfe
    @order = B2bOrder.find(params[:order_id])
    @number = params[:number].presence || @order.tiny_reference_number
    @items = @order.b2b_order_items.to_a
    @sender = params[:sender_name]

    attachments.inline['chase-logo.png'] = File.binread(LOGO_PATH)
    attachments["DANFE-#{@number}.pdf"] = WickedPdf.new.pdf_from_url(params[:danfe_url], page_size: 'A4')

    destination = @order.transfer_location&.name
    mail(to: params[:to], subject: "📦 Nota fiscal nº #{@number}#{" · Abastecimento #{destination}" if destination}")
  end
end
