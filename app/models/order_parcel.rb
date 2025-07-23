class OrderParcel < ApplicationRecord
  belongs_to :order_pdv
  
  validates :payment_method, presence: true
  validates :amount, presence: true, numericality: { greater_than: 0 }
  
  enum payment_method: {
    dinheiro: 0,
    cartao_credito: 1,
    cartao_debito: 2,
    pix: 3,
    transferencia: 4,
    cheque: 5,
    outros: 6
  }
  
  enum status: {
    pending: 'pending',
    paid: 'paid',
    failed: 'failed'
  }
  
  scope :by_method, ->(method) { where(payment_method: method) }
  scope :non_cash, -> { where.not(payment_method: 'dinheiro') }
  scope :pending, -> { where(status: 'pending') }
  
  def formatted_amount
    "R$ #{sprintf('%.2f', amount)}"
  end
  
  def payment_method_name
    case payment_method
    when 'dinheiro'
      '💵 Dinheiro'
    when 'cartao_credito'
      '💳 Cartão de Crédito'
    when 'cartao_debito'
      '💳 Cartão de Débito'
    when 'pix'
      '📱 PIX'
    when 'transferencia'
      '🏦 Transferência'
    when 'cheque'
      '📄 Cheque'
    else
      '❓ Outros'
    end
  end
  
  def payment_method_icon
    case payment_method
    when 'dinheiro'
      '💵'
    when 'cartao_credito', 'cartao_debito'
      '💳'
    when 'pix'
      '📱'
    when 'transferencia'
      '🏦'
    when 'cheque'
      '📄'
    else
      '❓'
    end
  end
  
  def summary
    "#{payment_method_name}: #{formatted_amount}"
  end
end
