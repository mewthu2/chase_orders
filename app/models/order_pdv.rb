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
end
