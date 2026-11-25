# Parcela a receber de um pedido de atacado pago por boleto (ou sem forma de pagamento: boleto à vista).
# O financeiro dá baixa em cada uma (paid_at); a comissão do consultor sai no mês da baixa.
# PIX e cartão não têm parcelas: contam como pagos na criação do pedido.
class B2bOrderPayment < ApplicationRecord
  belongs_to :b2b_order
  belongs_to :paid_by, class_name: 'User', optional: true

  validates :number, :due_date, :amount, presence: true

  scope :paid, -> { where.not(paid_at: nil) }
  scope :pending, -> { where(paid_at: nil) }
  scope :overdue, ->(today = Date.current) { pending.where(due_date: ...today) }
  scope :ordered, -> { order(:number) }

  def paid? = paid_at.present?
  def overdue?(today = Date.current) = !paid? && due_date < today
end
