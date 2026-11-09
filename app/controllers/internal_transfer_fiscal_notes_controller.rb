# Aba "Nota fiscal" da edição da Transferência Interna: emitir, transmitir de novo/consultar e excluir a
# NF-e de transferência de cada remessa, em homologação ou em produção (no máximo uma ativa por ambiente).
# A empresa da loja de origem emite para a da loja de destino, direto na SEFAZ.
class InternalTransferFiscalNotesController < ApplicationController
  guard_screen :internal_transfers, actions: { create: :edit, destroy: :edit, transmit: :edit }
  before_action :set_shipment
  before_action :set_note, only: [:destroy, :transmit]

  def create
    environment = params[:environment].to_s
    return back_to_notes(alert: 'Escolha homologação ou produção.') unless FiscalNote.environments.key?(environment)

    origin, destination = InternalTransferInvoicer.companies_for(@shipment)
    return back_to_notes(alert: 'Ligue as duas lojas a uma empresa (Empresas → Loja desta empresa) antes de emitir a nota.') if origin.nil? || destination.nil?
    return back_to_notes(alert: 'As duas lojas são da mesma empresa: não há nota de transferência.') if origin.id == destination.id

    note = Nfe::TransferGenerator.call(shipment: @shipment, company: origin, recipient_company: destination, environment: environment)
    Nfe::Transmitter.call(note)
    log_event('fiscal_note_issued', "NF-e nº #{note.number} (#{note.environment_label.downcase}) da remessa de #{@shipment.origin_location.name}: #{note.status_label.downcase}.")
    back_to_notes(**result_flash(note))
  rescue Nfe::TransferGenerator::Error, Nfe::Transmitter::Error => e
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
    log_event('fiscal_note_deleted', "#{label} da remessa de #{@shipment.origin_location.name} excluída.")
    back_to_notes(notice: "#{label} excluída. Já dá para emitir outra.")
  end

  private

  def set_shipment
    @transfer = InternalTransfer.find(params[:internal_transfer_id])
    @shipment = @transfer.shipments.find(params[:shipment_id])
  end

  def set_note
    @note = @shipment.fiscal_notes.find(params[:id])
  end

  def log_event(action, message)
    @transfer.events.create!(user: current_user, internal_transfer_shipment: @shipment, action: action, message: message)
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

  # A edição só abre enquanto a transferência é editável; depois disso a nota aparece na tela da transferência.
  def back_to_notes(**flash)
    path = @transfer.editable? ? edit_internal_transfer_path(@transfer, tab: 'nota') : internal_transfer_path(@transfer)
    redirect_to path, flash
  end
end
