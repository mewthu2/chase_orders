class FiscalNotesController < ApplicationController
  guard_screen :fiscal_notes
  before_action :set_note, only: [:show, :xml]
  before_action :set_order, only: [:new, :create]

  def index
    scope = FiscalNote.includes(:company, :b2b_order).recent
    scope = scope.where(status: params[:status]) if FiscalNote.statuses.key?(params[:status])
    scope = scope.where(company_id: params[:company_id]) if params[:company_id].present?
    @companies = Company.order(:legal_name)
    @fiscal_notes = scope.paginate(page: params[:page], per_page: 20)
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
    redirect_to fiscal_note_path(note), notice: 'Nota fiscal gerada e assinada (não transmitida à SEFAZ).'
  rescue Nfe::Generator::Error => e
    render_new_with_alert(e.message)
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

  def render_new_with_alert(message)
    load_new_page_data
    flash.now[:alert] = message
    render :new, status: :unprocessable_entity
  end
end
