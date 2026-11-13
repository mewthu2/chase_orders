# Configuração do atacado: frete fixo e os descontos do preço de atacado. Quem edita pedidos do atacado pode mudar.
class B2bSettingsController < ApplicationController
  guard_screen :b2b_orders

  def edit
    @setting = B2bSetting.current
  end

  def update
    @setting = B2bSetting.current
    if @setting.update(params.require(:b2b_setting).permit(:fixed_freight_value, :seamless_discount_percent, :default_discount_percent, :issuer_company_id, :sale_nature_id, :transfer_nature_id))
      redirect_to b2b_orders_path, notice: 'Configuração do atacado salva.'
    else
      render :edit, status: :unprocessable_entity
    end
  end
end
