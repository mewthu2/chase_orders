class FiscalNotesController < ApplicationController
  guard_screen :fiscal_notes, actions: { create_from_shopify: :create }
  before_action :set_note, only: [:show, :xml, :danfe, :transmit, :consult]
  before_action :set_order, only: [:new, :create]

  def index
    @scope = FiscalNote.includes(:company, :b2b_order, :order, :nature, :xml_attachment,
                                 internal_transfer_shipment: [:origin_location, { internal_transfer: :destination_location }]).recent
    @companies = Company.order(:legal_name)
  end

  def show; end

  # Escolha da empresa emissora para gerar a nota do pedido.
  def new
    load_new_page_data
  end

  def create
    company = Company.ready_to_issue.find_by(id: params[:company_id])
    return render_new_with_alert('Escolha uma empresa ativa com certificado digital válido.') unless company

    note = Nfe::Generator.call(order: @order, company: company)
    redirect_to fiscal_note_path(note), notice: 'Nota fiscal gerada e assinada. Confira e transmita à SEFAZ.'
  rescue Nfe::Generator::Error => e
    render_new_with_alert(e.message)
  end

  # Escolha do pedido da Shopify: busca pelo número e mostra o destinatário para conferir antes de emitir.
  def shopify
    load_shopify_page_data
    return if params[:order].blank?

    @shopify_order = Nfe::ShopifyOrder.find(params[:order])
    @recipient = @shopify_order.recipient
    @payment = @shopify_order.payment
  rescue Nfe::ShopifyOrder::NotFound => e
    flash.now[:alert] = e.message
  end

  def create_from_shopify
    @shopify_order = Nfe::ShopifyOrder.find(params[:shopify_order_id])
    @recipient = recipient_params.to_h.symbolize_keys
    @payment = payment_params.to_h.symbolize_keys
    nature = OperationNature.active.find_by(id: params[:operation_nature_id])
    company = Company.ready_to_issue.find_by(id: nature&.company_id)
    return render_shopify_with_alert('Escolha uma natureza de operação de empresa ativa com certificado válido.') unless company

    note = Nfe::ShopifyGenerator.call(company: company, nature: nature, shopify_order: @shopify_order, recipient: @recipient,
                                      payment: @payment, freight_mode: params[:freight_mode].presence || '0')
    Nfe::Transmitter.call(note)
    redirect_to fiscal_note_path(note), transmission_flash(note)
  rescue Nfe::ShopifyOrder::NotFound, Nfe::ShopifyGenerator::Error, Nfe::Transmitter::Error => e
    render_shopify_with_alert(e.message)
  end

  def transmit
    Nfe::Transmitter.call(@fiscal_note)
    redirect_to fiscal_note_path(@fiscal_note), transmission_flash(@fiscal_note)
  rescue Nfe::Transmitter::Error => e
    redirect_to fiscal_note_path(@fiscal_note), alert: e.message
  end

  def consult
    Nfe::Transmitter.call(@fiscal_note, consult: true)
    redirect_to fiscal_note_path(@fiscal_note), transmission_flash(@fiscal_note)
  rescue Nfe::Transmitter::Error => e
    redirect_to fiscal_note_path(@fiscal_note), alert: e.message
  end

  def xml
    unless @fiscal_note.xml_available?
      redirect_to fiscal_note_path(@fiscal_note), alert: 'Esta nota ainda não tem XML gerado.'
      return
    end

    send_data @fiscal_note.xml.download,
              filename: "NFe#{@fiscal_note.access_key}.xml",
              type: 'application/xml',
              disposition: 'attachment'
  end

  def danfe
    unless @fiscal_note.xml_available?
      redirect_to fiscal_note_path(@fiscal_note), alert: 'Esta nota ainda não tem XML gerado.'
      return
    end

    danfe = Nfe::Danfe.new(@fiscal_note.xml.download, cancelled: @fiscal_note.cancelada?)
    send_data danfe.render, filename: danfe.filename, type: 'application/pdf', disposition: 'attachment'
  end

  private

  def set_note
    @fiscal_note = FiscalNote.find(params[:id])
  end

  def set_order
    @order = B2bOrder.find(params[:b2b_order_id])
  end

  def load_new_page_data
    @companies = Company.ready_to_issue.order(:legal_name)
    @active_note = FiscalNote.active_statuses.find_by(b2b_order_id: @order.id)
  end

  def load_shopify_page_data
    @companies = Company.ready_to_issue.order(:legal_name)
    @natures = OperationNature.active.where(company: @companies).includes(:company).ordered
    # Com um pedido aberto a lista de recentes não aparece: nem consulta.
    @recent_orders = params[:order].present? ? Order.none : recent_site_orders
  end

  # Pedidos do site (o checkout grava o CPF em additional_cpf_cnpj) dos últimos dias que ainda não têm nota ativa.
  def recent_site_orders
    # Notas de homologação não tiram o pedido da lista: ele ainda precisa da nota real.
    with_note = FiscalNote.producao.where(status: FiscalNote::ACTIVE_STATUSES + ['erro']).where.not(order_id: nil).select(:order_id)
    # Pedidos do site têm o CPF nos atributos do checkout; o filtro roda no banco para não carregar centenas de pedidos.
    Order.includes(:customer).where(shopify_creation_date: 10.days.ago..).where.not(id: with_note)
         .where("JSON_SEARCH(orders.note_attributes, 'one', 'additional_cpf_cnpj', NULL, '$[*].name') IS NOT NULL")
         .order(shopify_creation_date: :desc).limit(40)
  end

  def recipient_params
    params.require(:recipient).permit(*Nfe::ShopifyGenerator::RECIPIENT_FIELDS)
  end

  def payment_params
    params.require(:payment).permit(:method, :installments, :description)
  end

  def transmission_flash(note)
    case note.status
    when 'autorizada' then { notice: "Nota #{note.number} autorizada pela SEFAZ (#{note.environment_label.downcase})." }
    when 'assinada' then { notice: 'A SEFAZ não conhece esta nota: ela pode ser transmitida.' }
    else { alert: note.error_message.presence || "Nota #{note.status_label.downcase}." }
    end
  end

  def render_shopify_with_alert(message)
    load_shopify_page_data
    flash.now[:alert] = message
    render :shopify, status: :unprocessable_entity
  end

  def render_new_with_alert(message)
    load_new_page_data
    flash.now[:alert] = message
    render :new, status: :unprocessable_entity
  end
end
