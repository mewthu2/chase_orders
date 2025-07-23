class OrderPdv < ApplicationRecord
  belongs_to :user
  has_many :order_pdv_items, dependent: :destroy
  has_many :order_parcels, dependent: :destroy
  has_many :products, through: :order_pdv_items

  accepts_nested_attributes_for :order_parcels, allow_destroy: true, reject_if: :all_blank

  validates :customer_name, presence: true
  validates :customer_email, presence: true
  validates :customer_phone, presence: true
  validates :customer_cpf, presence: true
  validates :address1, presence: true
  validates :address2, presence: true
  validates :city, presence: true
  validates :state, presence: true
  validates :zip, presence: true
  validates :store_type, presence: true
  validates :payment_method, presence: true
  validates :subtotal, :total_price, presence: true, numericality: { greater_than: 0 }

  validate :validate_parcels_total, if: :has_parcels?

  enum :status, {
    pending: 'pending',
    integrated: 'integrated',
    error: 'error'
  }

  enum :reservation_status, {
    no_reservation: 'no_reservation',
    reserved: 'reserved',
    reservation_error: 'reservation_error',
    partially_reserved: 'partially_reserved'
  }

  scope :recent, -> { order(created_at: :desc) }
  scope :by_status, ->(status) { where(status: status) if status.present? }

  def formatted_total
    "R$ #{sprintf('%.2f', total_price)}"
  end

  def formatted_subtotal
    "R$ #{sprintf('%.2f', subtotal)}"
  end

  def formatted_discount
    "R$ #{sprintf('%.2f', discount_amount)}"
  end

  def formatted_coupon_discount
    "R$ #{sprintf('%.2f', coupon_discount_amount || 0)}"
  end

  def has_coupon?
    coupon_code.present? && coupon_discount_amount.present? && coupon_discount_amount > 0
  end

  def manual_discount_amount
    (discount_amount || 0) - (coupon_discount_amount || 0)
  end

  def formatted_manual_discount
    "R$ #{sprintf('%.2f', manual_discount_amount)}"
  end

  def items_count
    order_pdv_items.sum(:quantity)
  end

  def can_retry_integration?
    pending? || error?
  end

  def integration_status_color
    case status
    when 'integrated'
      'success'
    when 'error'
      'danger'
    else
      'warning'
    end
  end

  def integration_status_text
    case status
    when 'integrated'
      'Integrado'
    when 'error'
      'Erro na Integração'
    else
      'Pendente'
    end
  end

  def reservation_status_text
    case reservation_status
    when 'reserved'
      'Estoque Reservado'
    when 'reservation_error'
      'Erro na Reserva'
    when 'partially_reserved'
      'Parcialmente Reservado'
    else
      'Sem Reserva'
    end
  end

  def reservation_status_color
    case reservation_status
    when 'reserved'
      'success'
    when 'reservation_error'
      'danger'
    when 'partially_reserved'
      'warning'
    else
      'secondary'
    end
  end

  def parsed_reservations
    return [] unless respond_to?(:inventory_reservations) && inventory_reservations.present?
    
    begin
      JSON.parse(inventory_reservations)
    rescue JSON::ParserError
      []
    end
  end

  def has_inventory_reserved?
    reserved? || partially_reserved?
  end

  def parsed_multi_payments
    return [] unless multi_payments.present?
    
    begin
      JSON.parse(multi_payments)
    rescue JSON::ParserError => e
      Rails.logger.error "Erro ao fazer parse de multi_payments: #{e.message}"
      []
    end
  end

  def has_multi_payments?
    payment_method == 'multi' && parsed_multi_payments.any?
  end

  def formatted_multi_payments
    return [] unless has_multi_payments?
    
    parsed_multi_payments.map do |payment|
      {
        method: payment['method'],
        amount: "R$ #{sprintf('%.2f', payment['amount'].to_f)}",
        raw_amount: payment['amount'].to_f
      }
    end
  end

  def total_multi_payments
    return 0 unless has_multi_payments?
    
    parsed_multi_payments.sum { |payment| payment['amount'].to_f }
  end

  def formatted_total_multi_payments
    "R$ #{sprintf('%.2f', total_multi_payments)}"
  end

  def payment_method_display
    case payment_method
    when 'multi'
      'Pagamento Múltiplo'
    when 'parcels'
      'Parcelado'
    when 'cartao_credito'
      'Cartão de Crédito'
    when 'cartao_debito'
      'Cartão de Débito'
    when 'pix'
      'PIX'
    when 'dinheiro'
      'Dinheiro'
    else
      payment_method.humanize
    end
  end

  def has_parcels?
    order_parcels.any?
  end

  def total_parcels_amount
    order_parcels.sum(:amount)
  end

  def formatted_total_parcels
    "R$ #{sprintf('%.2f', total_parcels_amount)}"
  end

  def parcels_pending_integration
    order_parcels.non_cash.pending
  end

  def all_parcels_paid?
    order_parcels.all?(&:paid?)
  end

  def payment_status
    if has_parcels?
      if all_parcels_paid?
        'paid'
      elsif order_parcels.any?(&:paid?)
        'partial'
      else
        'pending'
      end
    else
      'unknown'
    end
  end

  def payment_status_color
    case payment_status
    when 'paid'
      'success'
    when 'partial'
      'warning'
    else
      'danger'
    end
  end

  def payment_status_text
    case payment_status
    when 'paid'
      'Totalmente Pago'
    when 'partial'
      'Parcialmente Pago'
    when 'pending'
      'Pendente'
    else
      'Status Desconhecido'
    end
  end

  private

  def validate_parcels_total
    parcels_total = order_parcels.sum(&:amount)
    
    unless (parcels_total - total_price).abs < 0.01
      errors.add(:order_parcels, "O valor total das parcelas (#{sprintf('%.2f', parcels_total)}) deve ser igual ao total do pedido (#{sprintf('%.2f', total_price)})")
    end
  end
end
