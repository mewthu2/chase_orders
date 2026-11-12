# Configuração do atacado: o valor do frete fixo. Quem edita pedidos do atacado pode mudar.
class B2bSettingsController < ApplicationController
  guard_screen :b2b_orders

  def edit
    @setting = B2bSetting.current
  end

  def update
    @setting = B2bSetting.current
    if @setting.update(params.require(:b2b_setting).permit(:fixed_freight_value))
      redirect_to b2b_orders_path, notice: 'Frete fixo do atacado salvo.'
    else
      render :edit, status: :unprocessable_entity
    end
  end
end
