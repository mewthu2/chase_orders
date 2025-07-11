class OrderPdv < ApplicationRecord
  belongs_to :user
  has_many :order_pdv_items, dependent: :destroy
  has_many :products, through: :order_pdv_items

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

  enum status: {
    pending: 'pending',
    integrated: 'integrated', 
    error: 'error'
  }

  enum reservation_status: {
    none: 'none',
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
    return [] unless inventory_reservations.present?
    
    begin
      JSON.parse(inventory_reservations)
    rescue JSON::ParserError
      []
    end
  end

  def has_inventory_reserved?
    reserved? || partially_reserved?
  end
end
