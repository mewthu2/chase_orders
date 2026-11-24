# Configurações da NF-e do Abastecimento Lojas e da Transferência B2B → B2C: empresa emissora e natureza de
# operação usadas pelo Honey ao emitir a nota (na aba Nota fiscal do pedido e na etapa do XML do Log02).
class B2bTransferSettingsController < ApplicationController
  COPY = {
    'stock_transfer' => { title: 'Configurações do Abastecimento', back: :stock_transfers_path, icon: 'fas fa-dolly', what: 'do abastecimento das lojas' },
    'b2c_transfer' => { title: 'Configurações das Transferências B2B ⇄ B2C', back: :b2c_transfers_path, icon: 'fas fa-random', what: 'das transferências entre as filiais B2B e B2C, nos dois sentidos' }
  }.freeze

  guard_screen(actions: { edit: :edit, update: :edit }) { B2bOrdersController::KIND_SCREENS.fetch(order_kind) }
  helper_method :order_kind, :copy

  def edit
    @setting = B2bSetting.current
  end

  def update
    @setting = B2bSetting.current
    issuer_col, nature_col = B2bSetting::TRANSFER_KINDS.fetch(order_kind)
    attrs = params.require(:b2b_setting).permit(:"#{issuer_col}_id", :"#{nature_col}_id").to_h
    if order_kind == 'stock_transfer'
      # Nota de remessa (uma nota a mais do abastecimento): empresa, natureza e destinatário padrão.
      remessa = params.require(:b2b_setting).permit(:remessa_issuer_company_id, :remessa_nature_id,
                                                    remessa_recipient: B2bSetting::REMESSA_RECIPIENT_FIELDS).to_h
      attrs.merge!(remessa.slice('remessa_issuer_company_id', 'remessa_nature_id'))
      attrs['remessa_recipient'] = B2bSetting.normalize_recipient(remessa['remessa_recipient']) if remessa.key?('remessa_recipient')
    end
    attrs.merge!(b2c_to_b2b_attrs) if order_kind == 'b2c_transfer'
    if @setting.update(attrs)
      redirect_to send(copy[:back]), notice: 'Configurações da nota salvas.'
    else
      flash.now[:alert] = @setting.errors.full_messages.to_sentence
      render :edit, status: :unprocessable_entity
    end
  end

  private

  # B2C → B2B: empresa e natureza da nota de transferência e da nota de remessa, e o destinatário da remessa.
  # B2B → B2C: empresa, natureza e destinatário da nota de remessa (a de transferência usa b2c_issuer/b2c_nature).
  def b2c_to_b2b_attrs
    data = params.require(:b2b_setting).permit(:b2c_to_b2b_issuer_company_id, :b2c_to_b2b_nature_id, :b2c_to_b2b_remessa_issuer_company_id,
                                               :b2c_to_b2b_remessa_nature_id, :b2b_to_b2c_remessa_issuer_company_id, :b2b_to_b2c_remessa_nature_id,
                                               b2c_to_b2b_remessa_recipient: B2bSetting::REMESSA_RECIPIENT_FIELDS,
                                               b2b_to_b2c_remessa_recipient: B2bSetting::REMESSA_RECIPIENT_FIELDS).to_h
    %w[b2c_to_b2b_remessa_recipient b2b_to_b2c_remessa_recipient].each do |key|
      data[key] = B2bSetting.normalize_recipient(data[key]) if data.key?(key)
    end
    data
  end

  def order_kind
    kind = params[:order_kind].to_s
    B2bSetting::TRANSFER_KINDS.key?(kind) ? kind : raise(ActionController::RoutingError, 'Not Found')
  end

  def copy
    COPY.fetch(order_kind)
  end
end
