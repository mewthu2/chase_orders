class DashboardController < ApplicationController
  before_action :load_form_references, only: [:index]

  def index
    @orders_count = Tiny::Orders.get_all_orders('preparando_envio')[:numero_paginas]
  end

  def orders_tiny
    @orders = Tiny::Orders.get_all_orders(params[:situacao])
  end

  private

  def load_form_references
  end
end
