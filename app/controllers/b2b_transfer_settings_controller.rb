# Configurações da NF-e do Abastecimento Lojas e da Transferência B2B → B2C: empresa emissora e natureza de
# operação usadas pelo Honey ao emitir a nota (na aba Nota fiscal do pedido e na etapa do XML do Log02).
class B2bTransferSettingsController < ApplicationController
  COPY = {
    'stock_transfer' => { title: 'Configurações do Abastecimento', back: :stock_transfers_path, icon: 'fas fa-dolly', what: 'do abastecimento das lojas' },
    'b2c_transfer' => { title: 'Configurações da Transferência B2C', back: :b2c_transfers_path, icon: 'fas fa-random', what: 'da transferência para a filial B2C' }
  }.freeze

  guard_screen(actions: { edit: :edit, update: :edit }) { B2bOrdersController::KIND_SCREENS.fetch(order_kind) }
  helper_method :order_kind, :copy

  def edit
    @setting = B2bSetting.current
  end

  def update
    @setting = B2bSetting.current
    issuer_col, nature_col = B2bSetting::TRANSFER_KINDS.fetch(order_kind)
    attrs = params.require(:b2b_setting).permit(:"#{issuer_col}_id", :"#{nature_col}_id")
    if @setting.update(attrs)
      redirect_to send(copy[:back]), notice: 'Configurações da nota salvas.'
    else
      flash.now[:alert] = @setting.errors.full_messages.to_sentence
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def order_kind
    kind = params[:order_kind].to_s
    B2bSetting::TRANSFER_KINDS.key?(kind) ? kind : raise(ActionController::RoutingError, 'Not Found')
  end

  def copy
    COPY.fetch(order_kind)
  end
end
