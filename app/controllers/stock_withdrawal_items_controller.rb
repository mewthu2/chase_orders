# Reverter uma linha já retirada: devolve a quantidade ao estoque no Shopify.
class StockWithdrawalItemsController < ApplicationController
  guard_screen :stock_withdrawals

  def revert
    withdrawal = StockWithdrawal.find(params[:stock_withdrawal_id])
    item = withdrawal.items.includes(:product, :location).find(params[:id]) # 404 se a linha é de outra retirada

    StockWithdrawalReverter.call(item, user: current_user)
    redirect_to stock_withdrawal_path(withdrawal),
                notice: "Linha #{item.product.sku} revertida: #{item.quantity} unidade(s) devolvida(s) ao estoque de #{item.location.name} no Shopify."
  rescue StockWithdrawalReverter::Error => e
    redirect_to stock_withdrawal_path(params[:stock_withdrawal_id]), alert: e.message
  end
end
