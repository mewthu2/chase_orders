class AttemptsController < ApplicationController
  before_action :load_form_references, only: [:index]
  protect_from_forgery except: :verify_attempts

  def index
    @attempts = Attempt.search(params[:search])
                       .where(status: params[:status], kinds: params[:kinds])
                       .by_status(params[:status], params[:kinds])
                       .order(created_at: :desc)
                       .paginate(page: params[:page], per_page: params_per_page(params[:per_page]))
  end

  def verify_attempts
    @attempts = Attempt.where(tiny_order_id: params[:tiny_order_id])
                       .paginate(page: params[:page], per_page: params_per_page(params[:per_page]))
  end

  def reprocess
    attempt = Attempt.find(params[:attempt_id])
    begin
      case attempt.kinds
      when 'create_correios_order'
        order = Tiny::Orders.obtain_order(attempt.tiny_order_id)
        CreateCorreiosLogOrdersJob.perform_now('one', order)
      when 'send_xml'
        SendXmlCorreiosLogJob.perform_now('one', attempt)
      when 'emission_invoice'
        InvoiceEmitionsJob.perform_now('one', attempt)
      when 'get_tracking'
        GetTrackingJob.perform_now('one', attempt)
      end
    rescue StandardError => e
      redirect_to(root_path, alert: "Ocorreu um erro no reprocessamento: #{e}")
    end
    redirect_to(root_path, notice: "Pedido #{attempt.tiny_order_id} reprocessado, retorno: #{attempt.status_code} - #{attempt.message}")
  end

  private

  def load_form_references; end
end