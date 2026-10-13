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
    created = created_in_correios(reservations.map(&:tiny_order_id).uniq)
    reservations.reject! { |row| created.include?(row.tiny_order_id) }

    @groups = reservations.group_by(&:sku)
    @product_names = Product.where(sku: @groups.keys).pluck(:sku, :shopify_product_name)
                            .to_h { |sku, name| [sku.to_s.upcase, name] }
    @order_refs = order_refs(reservations)
    @kpis = { orders: reservations.map(&:tiny_order_id).uniq.size, skus: @groups.size,
              units: reservations.sum(&:quantity).ceil }
    render :index
  end

  def creation_attempts(tiny_order_ids)
    Attempt.where(kinds: StockReservationRefresher::ACCOUNTS.fetch(@account)[:attempt_kind], tiny_order_id: tiny_order_ids)
  end

  # Pedido que já tem número no Correios Log já está reservado no WMS: não aparece aqui, mesmo
  # antes da próxima atualização da fila.
  def created_in_correios(tiny_order_ids)
    attempts = creation_attempts(tiny_order_ids)
    attempts.where(status: :success).or(attempts.where('order_correios_id > 0')).pluck(:tiny_order_id).map(&:to_s).to_set
  end

  # Nota fiscal: a guardada na reserva tem prioridade; a tentativa de criação no Correios cobre
  # notas emitidas depois da foto.
  def order_refs(reservations)
    refs = Hash.new { |hash, key| hash[key] = {} }

    attempts = creation_attempts(reservations.map(&:tiny_order_id).uniq).order(:updated_at)
    attempts.pluck(:tiny_order_id, :id_nota_fiscal).each do |tiny_order_id, invoice_id|
      refs[tiny_order_id.to_s][:invoice] = invoice_id.to_s if invoice_id.to_i.positive?
    end

    reservations.each do |row|
      refs[row.tiny_order_id][:invoice] = row.invoice_id if row.invoice_id.present?
    end
    refs
  end
end
