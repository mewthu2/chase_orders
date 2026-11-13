# Tabela de frete do atacado (faixas de valor do pedido → preço do frete). Quem vê pedidos do atacado
# consulta; quem edita pedidos do atacado mexe nas faixas.
class B2bFreightRatesController < ApplicationController
  guard_screen :b2b_orders, actions: { index: :view, new: :edit, create: :edit, edit: :edit, update: :edit, destroy: :edit }
  before_action :set_rate, only: [:edit, :update, :destroy]

  def index
    @rates = B2bFreightRate.ordered
  end

  def new
    last = B2bFreightRate.ordered.last
    @rate = B2bFreightRate.new(min_value: last ? last.max_value + 0.01 : 0, max_value: last ? last.max_value + 5_000 : 5_000)
  end

  def create
    @rate = B2bFreightRate.new(rate_params)
    if @rate.save
      redirect_to b2b_freight_rates_path, notice: 'Faixa de frete criada.'
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @rate.update(rate_params)
      redirect_to b2b_freight_rates_path, notice: 'Faixa de frete atualizada.'
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @rate.destroy
    redirect_to b2b_freight_rates_path, notice: 'Faixa de frete removida.'
  end

  private

  def set_rate
    @rate = B2bFreightRate.find(params[:id])
  end

  def rate_params
    params.require(:b2b_freight_rate).permit(:min_value, :max_value, :price)
  end
end
