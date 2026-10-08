# Reservas de estoque: itens dos pedidos que estão na fila do Tiny (B2B = Tiny2, B2C = Tiny3).
class StockReservationsController < ApplicationController
  guard_screen :stock_reservations_b2b, only: :b2b
  guard_screen :stock_reservations_b2c, only: :b2c
  before_action :set_refresh_account, only: :refresh

  def b2b = render_account('b2b')
  def b2c = render_account('b2c')

  def refresh
    StockReservationRefreshJob.perform_later(@account)
    redirect_to account_path(@account), notice: 'Atualização das reservas iniciada. A página recarrega sozinha quando terminar.'
  end

  private

  def set_refresh_account
    @account = params[:account].to_s
    return head :not_found unless StockReservationRefresher::ACCOUNTS.key?(@account)

    authorize_screen!("stock_reservations_#{@account}")
  end

  def account_path(account)
    account == 'b2b' ? b2b_stock_reservations_path : b2c_stock_reservations_path
  end

  def render_account(account)
    @account = account
    @refresh = StockReservationRefresh.for(account)
    @sku_query = params[:sku].to_s.strip.upcase

    scope = StockReservation.where(account:)
    scope = scope.where('sku LIKE ?', "%#{StockReservation.sanitize_sql_like(@sku_query)}%") if @sku_query.present?
    reservations = scope.order(:sku, :order_date, :tiny_order_number).to_a

    @groups = reservations.group_by(&:sku)
    @product_names = Product.where(sku: @groups.keys).pluck(:sku, :shopify_product_name)
                            .to_h { |sku, name| [sku.to_s.upcase, name] }
    @kpis = { orders: reservations.map(&:tiny_order_id).uniq.size, skus: @groups.size,
              units: reservations.sum(&:quantity).ceil }
    render :index
  end
end
