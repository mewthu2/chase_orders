# Encomendas de um catálogo vistas pelo Honey: abrir (marca como vista), alterar e virar pedido.
class B2bCatalogOrdersController < ApplicationController
  guard_screen :b2b_catalogs
  before_action :set_order

  def show
    @catalog_order.update!(status: :seen) if @catalog_order.pending?
    @quantities = @catalog_order.items.to_h { |item| [item.b2b_catalog_variant_id, item.quantity] }
  end

  def edit
    @quantities = @catalog_order.items.to_h { |item| [item.b2b_catalog_variant_id, item.quantity] }
  end

  def update
    if @catalog_order.converted?
      redirect_to b2b_catalog_catalog_order_path(@catalog, @catalog_order), alert: 'Esta encomenda já virou pedido e não pode mais ser alterada.'
      return
    end

    quantities = params.fetch(:quantities, {}).to_unsafe_h.transform_keys(&:to_i).transform_values(&:to_i)
    @catalog_order.replace_items!(quantities, edited_by: current_user.name)
    redirect_to b2b_catalog_catalog_order_path(@catalog, @catalog_order), notice: 'Encomenda alterada. O cliente vê a nova versão no link.'
  end

  private

  def set_order
    @catalog = B2bCatalog.find(params[:b2b_catalog_id])
    @catalog_order = @catalog.catalog_orders.find(params[:id])
  end
end
