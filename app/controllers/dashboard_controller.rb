class DashboardController < ApplicationController
  before_action :load_form_references, only: [:index]

  def index
    @preparando_envio = Tiny::Orders.get_all_orders('preparando_envio')[:pedidos]
    @aberto = Tiny::Orders.get_all_orders('aberto')[:pedidos]
    @aprovado = Tiny::Orders.get_all_orders('aprovado')[:pedidos]
    @orders = Tiny::Orders.get_all_orders('preparando_envio')
  end

  def orders_tiny
    @orders = Tiny::Orders.get_all_orders(params[:situacao])
    respond_to do |f|
      f.js { render layout: false, content_type: 'text/javascript' }
      f.html
    end
  end

  private

  def load_form_references; end
end
