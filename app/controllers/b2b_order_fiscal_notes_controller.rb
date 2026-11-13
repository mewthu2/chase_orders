# Aba "Nota fiscal" da edição dos pedidos B2B (atacado, abastecimento e transferência B2C), no molde da
# Transferência Interna: emitir, enviar à SEFAZ/consultar e excluir a NF-e do pedido, em homologação ou em
# produção (no máximo uma ativa por ambiente). Empresa e natureza vêm da Configuração do atacado.
class B2bOrderFiscalNotesController < ApplicationController
  KIND_SCREENS = B2bOrdersController::KIND_SCREENS

  guard_screen(actions: { create: :edit, destroy: :edit, transmit: :edit }) { KIND_SCREENS.fetch(order.kind, :b2b_orders) }
  before_action :set_note, only: [:destroy, :transmit]

  def create
    environment = params[:environment].to_s
    return back_to_notes(alert: 'Escolha homologação ou produção.') unless FiscalNote.environments.key?(environment)

    setting = B2bSetting.current
    company = setting.issuer
    nature = setting.nature_for(order)
    return back_to_notes(alert: 'Escolha a empresa emissora e a natureza em Configuração do atacado.') unless company && nature

    CompanyOperationNature.find_or_create_by!(company:, operation_nature: nature)
    note = Nfe::Generator.call(order:, company:, nature:, environment:)
    Nfe::Transmitter.call(note)
    back_to_notes(**result_flash(note))
  rescue Nfe::Generator::Error, Nfe::Transmitter::Error, ActiveRecord::RecordInvalid => e
    back_to_notes(alert: e.message)
  end

  # Assinada: envia de novo. Sem resposta (erro): consulta pela chave antes de qualquer outra coisa.
  def transmit
    Nfe::Transmitter.call(@note, consult: @note.erro?)
    back_to_notes(**result_flash(@note))
  rescue Nfe::Transmitter::Error => e
    back_to_notes(alert: e.message)
  end

  def destroy
    reason = @note.undeletable_reason
    return back_to_notes(alert: reason) if reason

    label = "NF-e nº #{@note.number} (#{@note.environment_label.downcase})"
    @note.discard!
    back_to_notes(notice: "#{label} excluída. Já dá para emitir outra.")
  end

  private

  def order
    @order ||= B2bOrder.find(params[:b2b_order_id])
  end

  def set_note
    @note = FiscalNote.where(b2b_order_id: order.id).find(params[:id])
  end

  def result_flash(note)
    env = note.homologacao? ? ' (homologação, sem valor fiscal)' : ''
    if note.autorizada?
      { notice: "NF-e nº #{note.number}#{env} autorizada." }
    elsif note.erro?
      { alert: "NF-e nº #{note.number}#{env} ficou sem resposta da SEFAZ: #{note.error_message}. Consulte de novo em instantes." }
    else
      { alert: "NF-e nº #{note.number}#{env} não foi autorizada: #{note.error_message.presence || note.sefaz_message}" }
    end
  end

  def back_to_notes(**flash)
    path = { 'sale' => :edit_b2b_order_path, 'stock_transfer' => :edit_stock_transfer_path, 'b2c_transfer' => :edit_b2c_transfer_path }[order.kind]
    redirect_to send(path, order, tab: 'nota'), flash
  end
end
