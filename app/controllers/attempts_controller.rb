class AttemptsController < ApplicationController
  before_action :load_form_references, only: [:index]
  protect_from_forgery except: :verify_attempts

  def index
    @attempts = Attempt.search(params[:search])

    if params[:status] == 'nil'
      @attempts = @attempts.where(status: nil)
    elsif params[:status].present?
      @attempts = @attempts.where(status: params[:status])
    end

    @attempts = @attempts.where(kinds: params[:kinds]) if params[:kinds].present?

    @attempts = @attempts.order(created_at: :desc)
                         .paginate(page: params[:page], per_page: params_per_page(params[:per_page]))
  end

  def verify_attempts
    @attempts = Attempt.where(tiny_order_id: params[:tiny_order_id])
                       .order(created_at: :desc)
                       .paginate(page: params[:page], per_page: params_per_page(params[:per_page]))
  end

  def reprocess
    attempt = Attempt.find(params[:attempt_id])
    begin
      case attempt.kinds
      when 'create_correios_order'
        order = Tiny::Orders.obtain_order(ENV.fetch('TOKEN_TINY3_PRODUCTION'), attempt.tiny_order_id)
        CreateCorreiosLogOrdersJob.perform_now('one', order)
      when 'send_xml'
        SendXmlCorreiosLogJob.perform_now('one', attempt)
      when 'emission_invoice'
        InvoiceEmitionsJob.perform_now('one', attempt)
      when 'get_tracking'
        GetTrackingJob.perform_now('one', attempt)
      when 'transfer_tiny_to_shopify_order'
        TransferTinyToShopifyOrderJob.perform_now('one', attempt.tiny_order_id)
      end
      redirect_to(attempts_path(kinds: attempt.kinds), notice: "Pedido #{attempt.tiny_order_id} reprocessado com sucesso.")
    rescue StandardError => e
      redirect_to(attempts_path(kinds: attempt.kinds), alert: "Ocorreu um erro no reprocessamento: #{e}")
    end
  end

  private

  def load_form_references; end
  
  def params_per_page(per_page_param)
    per_page = (per_page_param || 20).to_i
    [10, 20, 50, 100].include?(per_page) ? per_page : 20
  end
end
