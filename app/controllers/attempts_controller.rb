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

    if params[:channel] == 'b2b'
      @attempts = @attempts.where(kinds: Attempt::B2B_KINDS)
    elsif params[:channel] == 'b2c'
      @attempts = @attempts.where(kinds: Attempt::B2C_KINDS)
    end

    @attempts = @attempts.where(kinds: params[:kinds]) if params[:kinds].present?

    @attempts = @attempts.order(created_at: :desc)
                         .paginate(page: params[:page], per_page: params_per_page(params[:per_page]))
    preload_address_corrections
  end

  def verify_attempts
    @attempts = Attempt.where(tiny_order_id: params[:tiny_order_id])

    @attempts = @attempts.where(kinds: params[:kinds]) if params[:kinds].present?

    respond_to do |format|
      format.html do
        @attempts = @attempts.limit(20)
                             .order(created_at: :desc)
                             .paginate(page: params[:page], per_page: params_per_page(params[:per_page]))
        preload_address_corrections
        load_address_correction_banner
      end
      format.json do
        attempts = @attempts.order(created_at: :desc)
                             .paginate(page: params[:page], per_page: params_per_page(params[:per_page]))
        render json: {
          attempts: attempts.map { |a|
            {
              id: a.id,
              kinds: a.kinds,
              status: a.status,
              status_code: a.status_code,
              message: a.message,
              error: a.error,
              created_at: a.created_at,
              has_xml: a.xml_nota.present?
            }
          },
          pagination: {
            current_page: attempts.current_page,
            total_pages: attempts.total_pages,
            total_entries: attempts.total_entries
          }
        }
      end
    end
  end

  def bairro_lookup
    attempt = Attempt.find(params[:attempt_id])
    token = bairro_fix_token(attempt)
    pedido = Tiny::Orders.obtain_order(token, attempt.tiny_order_id)[:pedido]

    unless pedido.present? && pedido[:cliente].present?
      return render json: { success: false, error: 'Pedido não encontrado na Tiny' }, status: :unprocessable_entity
    end

    cliente = pedido[:cliente]
    endereco_entrega = pedido[:endereco_entrega]
    fonte = endereco_entrega.presence || cliente

    render json: {
      success: true,
      kinds: attempt.kinds,
      tiny_order_id: attempt.tiny_order_id,
      cpf_cnpj: cliente[:cpf_cnpj].to_s.gsub(/\D/, ''),
      endereco: fonte[:endereco],
      numero: fonte[:numero],
      complemento: fonte[:complemento],
      bairro: fonte[:bairro],
      cep: fonte[:cep],
      cidade: fonte[:cidade],
      uf: fonte[:uf],
      endereco_entrega_presente: endereco_entrega.present?
    }
  rescue StandardError => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  # A Tiny não tem endpoint pra alterar o endereço de entrega de um pedido
  # específico (só o cadastro do cliente, que não reflete no pedido quando ele
  # tem endereço de entrega próprio). Por isso a correção fica só no Honey: ao
  # recriar o pedido no Correios, esse endereço substitui o vindo da Tiny.
  def fix_bairro
    attempt = Attempt.find(params[:attempt_id])
    address = params.permit(:endereco, :numero, :complemento, :bairro, :cep, :cidade, :uf).to_h.symbolize_keys

    if address[:bairro].blank?
      return render json: { success: false, error: 'Bairro é obrigatório' }, status: :unprocessable_entity
    end

    correction = AddressCorrection.find_or_initialize_by(tiny_order_id: attempt.tiny_order_id.to_s)
    correction.assign_attributes(address)

    if correction.save
      render json: { success: true }
    else
      render json: { success: false, error: correction.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end
  rescue StandardError => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  # "Já corrigi no Tiny": o usuário corrigiu a nota no Tiny (a API não permite ao Honey fazer isso).
  # Libera o pedido da espera e tenta emitir a nota de novo, mostrando o resultado na hora.
  def mark_tiny_fixed
    tiny_order_id = params[:tiny_order_id].to_s
    back = mark_tiny_fixed_return_path(tiny_order_id)
    correction = AddressCorrection.for(tiny_order_id)

    if correction.nil?
      return redirect_to(back, alert: 'Não há correção de endereço registrada para este pedido.')
    elsif !correction.awaiting_tiny_fix?
      return redirect_to(back, alert: 'Este pedido não está aguardando correção da nota no Tiny.')
    end

    correction.release!
    invoice_attempt = Attempt.where(tiny_order_id: tiny_order_id, kinds: %i[emission_invoice emission_invoice_tiny2])
                             .where.not(id_nota_fiscal: nil).order(:created_at).last
    return redirect_to(back, notice: 'Marcado como corrigido. A emissão automática tentará enviar a nota de novo.') unless invoice_attempt

    job = invoice_attempt.kinds == 'emission_invoice_tiny2' ? InvoiceEmitionsJob2 : InvoiceEmitionsJob
    result = job.new.one_emission(invoice_attempt)
    redirect_to back, **mark_tiny_fixed_flash(result, correction.reload)
  end

  def download_xml
    attempt = Attempt.find(params[:id])

    if attempt.xml_nota.present?
      send_data attempt.xml_nota,
                filename: "attempt_#{attempt.id}.xml",
                type: 'application/xml',
                disposition: 'attachment'
    else
      redirect_to attempts_path, alert: "Este registro não possui XML disponível."
    end
  end

  def reprocess
    attempt = Attempt.find(params[:attempt_id])
    begin
      case attempt.kinds
      when 'create_correios_order'
        order = Tiny::Orders.obtain_order(ENV.fetch('TOKEN_TINY_PRODUCTION'), 911651334)
        CreateCorreiosLogOrdersJob.perform_now('one', order)
      when 'send_xml'
        SendXmlCorreiosLogJob.perform_now('one', attempt)
      when 'emission_invoice'
        InvoiceEmitionsJob.perform_now('one', attempt)
      when 'get_tracking'
        GetTrackingJob.perform_now('one', attempt)
      when 'transfer_tiny_to_shopify_order'
        TransferTinyToShopifyOrderJob.perform_now('one', attempt.tiny_order_id)
      when 'create_correios_order_tiny2'
        order = Tiny::Orders.obtain_order(ENV.fetch('TOKEN_TINY2_PRODUCTION'), attempt.tiny_order_id)
        CreateCorreiosLogOrdersJob2.perform_now('one', order)
      when 'send_xml_tiny2'
        SendXmlCorreiosLogJob2.perform_now('one', attempt)
      when 'emission_invoice_tiny2'
        InvoiceEmitionsJob2.perform_now('one', attempt)
      when 'get_tracking_tiny2'
        GetTrackingJob2.perform_now('one', attempt)
      end
      redirect_to(attempts_path(kinds: attempt.kinds), notice: "Pedido #{attempt.tiny_order_id} reprocessado com sucesso.")
    rescue StandardError => e
      redirect_to(attempts_path(kinds: attempt.kinds), alert: "Ocorreu um erro no reprocessamento: #{e}")
    end
  end

  private

  # Volta para a tela de onde o usuário clicou (só destinos conhecidos, nada de URL vinda do formulário).
  def mark_tiny_fixed_return_path(tiny_order_id)
    case params[:return_to]
    when 'invoice_emition' then invoice_emition_dashboard_index_path
    when 'invoice_emition_b2b' then invoice_emition_b2b_dashboard_index_path
    else verify_attempts_attempts_path(tiny_order_id: tiny_order_id)
    end
  end

  def mark_tiny_fixed_flash(result, correction)
    return { notice: 'Nota enviada com sucesso no Tiny.' } if result.success?
    return { alert: "O Tiny ainda recusou o endereço da nota: #{result.message}" } if correction.awaiting_tiny_fix?

    { alert: "O Tiny recusou a nota: #{result.message.presence || result.error.presence || 'motivo não informado'}" }
  end

  # Uma consulta só para as correções dos pedidos da página (evita uma consulta por linha).
  def preload_address_corrections
    ids = @attempts.map { |attempt| attempt.tiny_order_id.to_s }.reject(&:blank?).uniq
    @address_corrections = AddressCorrection.where(tiny_order_id: ids).index_by(&:tiny_order_id)
  end

  def load_address_correction_banner
    return if params[:tiny_order_id].blank?

    @address_correction = AddressCorrection.for(params[:tiny_order_id])
    return unless @address_correction

    @address_correction_invoice_id = Attempt.where(tiny_order_id: params[:tiny_order_id]).where.not(id_nota_fiscal: nil).order(:created_at).last&.id_nota_fiscal
  end

  def bairro_fix_token(attempt)
    attempt.kinds == 'create_correios_order_tiny2' ? ENV.fetch('TOKEN_TINY2_PRODUCTION') : ENV.fetch('TOKEN_TINY3_PRODUCTION')
  end

  def load_form_references; end

  def params_per_page(per_page_param)
    per_page = (per_page_param || 20).to_i
    [10, 20, 50, 100].include?(per_page) ? per_page : 20
  end
end
