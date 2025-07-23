class OrderParcelsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_order_pdv
  before_action :set_order_parcel, only: [:show, :update, :check_payment_status, :mark_as_paid, :mark_as_failed]

  def index
    @order_parcels = @order_pdv.order_parcels.order(:created_at)
    
    respond_to do |format|
      format.html
      format.json { render json: @order_parcels }
    end
  end

  def show
    respond_to do |format|
      format.html
      format.json { render json: @order_parcel }
    end
  end

  def update
    if @order_parcel.update(order_parcel_params)
      render json: { 
        success: true, 
        message: 'Parcela atualizada com sucesso!',
        parcel: @order_parcel
      }
    else
      render json: { 
        success: false, 
        message: 'Erro ao atualizar parcela',
        errors: @order_parcel.errors.full_messages
      }
    end
  end

  def check_payment_status
    return render json: { success: false, message: 'Parcela em dinheiro não precisa de verificação' } if @order_parcel.cash_payment?
    return render json: { success: false, message: 'Integration ID não encontrado' } unless @order_parcel.integration_id.present?

    begin
      # Aqui você implementará a integração com Mercado Pago
      # Por enquanto, vamos simular a verificação
      payment_status = check_mercado_pago_status(@order_parcel.integration_id)
      
      case payment_status[:status]
      when 'approved'
        @order_parcel.update!(
          status: 'paid',
          paid_at: Time.current,
          payment_data: payment_status[:data]
        )
        
        render json: { 
          success: true, 
          message: 'Pagamento confirmado!',
          status: 'paid'
        }
      when 'rejected', 'cancelled'
        @order_parcel.update!(
          status: 'failed',
          failed_at: Time.current,
          payment_data: payment_status[:data]
        )
        
        render json: { 
          success: true, 
          message: 'Pagamento rejeitado/cancelado',
          status: 'failed'
        }
      else
        render json: { 
          success: true, 
          message: 'Pagamento ainda pendente',
          status: 'pending'
        }
      end
    rescue => e
      Rails.logger.error "Erro ao verificar status do pagamento: #{e.message}"
      render json: { 
        success: false, 
        message: "Erro ao verificar pagamento: #{e.message}"
      }
    end
  end

  def mark_as_paid
    if @order_parcel.update(status: 'paid', paid_at: Time.current)
      render json: { 
        success: true, 
        message: 'Parcela marcada como paga!',
        status: 'paid'
      }
    else
      render json: { 
        success: false, 
        message: 'Erro ao marcar parcela como paga',
        errors: @order_parcel.errors.full_messages
      }
    end
  end

  def mark_as_failed
    if @order_parcel.update(status: 'failed', failed_at: Time.current)
      render json: { 
        success: true, 
        message: 'Parcela marcada como falhada!',
        status: 'failed'
      }
    else
      render json: { 
        success: false, 
        message: 'Erro ao marcar parcela como falhada',
        errors: @order_parcel.errors.full_messages
      }
    end
  end

  private

  def set_order_pdv
    @order_pdv = OrderPdv.find(params[:order_pdv_id])
  end

  def set_order_parcel
    @order_parcel = @order_pdv.order_parcels.find(params[:id])
  end

  def order_parcel_params
    params.require(:order_parcel).permit(:payment_method, :amount, :notes, :status)
  end

  def check_mercado_pago_status(integration_id)
    # Implementação futura da integração com Mercado Pago
    # Por enquanto, retorna um status simulado

    # Exemplo de como seria a implementação real:
    # require 'net/http'
    # require 'json'
    # 
    # uri = URI("https://api.mercadopago.com/v1/payments/#{integration_id}")
    # http = Net::HTTP.new(uri.host, uri.port)
    # http.use_ssl = true
    # 
    # request = Net::HTTP::Get.new(uri)
    # request['Authorization'] = "Bearer #{ENV['MERCADO_PAGO_ACCESS_TOKEN']}"
    # 
    # response = http.request(request)
    # payment_data = JSON.parse(response.body)
    # 
    # {
    #   status: payment_data['status'],
    #   data: payment_data
    # }

    # Simulação para desenvolvimento
    {
      status: ['pending', 'approved', 'rejected'].sample,
      data: {
        id: integration_id,
        status: 'pending',
        checked_at: Time.current.iso8601
      }
    }
  end
end
