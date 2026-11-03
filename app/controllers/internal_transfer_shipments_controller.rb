# Ações de uma remessa (uma loja de origem) dentro de uma transferência interna: reservar,
# marcar como enviada (com rastreio), receber e cancelar. Cada uma é síncrona, sem fila.
class InternalTransferShipmentsController < ApplicationController
  guard_screen :internal_transfers, actions: { cancel: :destroy }
  before_action :set_transfer
  before_action :set_shipment

  def reserve
    authorize_origin!
    return if performed?

    summary = InternalTransferReservationProcessor.call(@shipment, user: current_user)
    if summary.failed.zero?
      redirect_to internal_transfer_path(@transfer), notice: "#{summary.reserved} item(ns) reservado(s) com sucesso."
    else
      redirect_to internal_transfer_path(@transfer),
                  alert: "Reserva com falha(s): #{summary.reserved} reservado(s), #{summary.failed} com falha. Veja os motivos na remessa."
    end
  rescue InternalTransferReservationProcessor::Error => e
    redirect_to internal_transfer_path(@transfer), alert: e.message
  end

  # Idempotente para o código de rastreio: se a remessa já estiver enviada, só atualiza o código.
  def ship
    authorize_origin!
    return if performed?

    unless @shipment.sendable? || @shipment.enviado?
      redirect_to internal_transfer_path(@transfer), alert: 'Esta remessa ainda não foi reservada.'
      return
    end

    tracking_code = params[:tracking_code].presence
    if @shipment.sendable?
      ship_with_note(tracking_code)
    else
      @shipment.update!(tracking_code: tracking_code)
      redirect_to internal_transfer_path(@transfer), notice: 'Código de rastreio atualizado.'
    end
  end

  def receive
    authorize_destination!
    return if performed?

    summary = InternalTransferReceiptProcessor.call(@shipment, user: current_user)
    if summary.failed.zero?
      redirect_to internal_transfer_path(@transfer), notice: "#{summary.received} item(ns) recebido(s) com sucesso."
    else
      redirect_to internal_transfer_path(@transfer),
                  alert: "Recebimento com falha(s): #{summary.received} recebido(s), #{summary.failed} com falha."
    end
  rescue InternalTransferReceiptProcessor::Error => e
    redirect_to internal_transfer_path(@transfer), alert: e.message
  end

  def cancel
    authorize_cancel!
    return if performed?

    InternalTransferCancellationProcessor.call(@shipment, user: current_user)
    redirect_to internal_transfer_path(@transfer), notice: 'Remessa cancelada.'
  rescue InternalTransferCancellationProcessor::Error => e
    redirect_to internal_transfer_path(@transfer), alert: e.message
  end

  private

  # A nota de transferência sai antes da mercadoria: só marca como enviada com a nota autorizada (ou sem
  # nota, quando as duas lojas são da mesma empresa). O lock evita duas notas num clique duplo.
  def ship_with_note(tracking_code)
    note = nil
    sent = @shipment.with_lock do
      next false unless @shipment.sendable?

      note = InternalTransferInvoicer.call(@shipment)
      next false if note && !note.autorizada?

      @shipment.update!(status: :enviado, tracking_code: tracking_code, sent_at: Time.current, sent_by: current_user)
      true
    end

    if sent
      note_text = note ? " com a NF-e nº #{note.number}" : ''
      message = "Remessa de #{@shipment.origin_location.name} marcada como enviada#{note_text}#{" (rastreio #{tracking_code})" if tracking_code}."
      InternalTransferEvent.create!(internal_transfer: @transfer, internal_transfer_shipment: @shipment, user: current_user, action: 'shipped', message: message)
      redirect_to internal_transfer_path(@transfer), notice: note ? "NF-e nº #{note.number} autorizada e remessa marcada como enviada." : 'Remessa marcada como enviada.'
    elsif note
      reason = note.error_message.presence || note.sefaz_message.presence || 'sem resposta da SEFAZ'
      redirect_to internal_transfer_path(@transfer),
                  alert: "A nota de transferência não foi autorizada (#{reason}). A remessa continua reservada: corrija e clique em Enviar de novo."
    else
      redirect_to internal_transfer_path(@transfer), alert: 'Esta remessa já foi enviada.'
    end
  rescue InternalTransferInvoicer::Error => e
    redirect_to internal_transfer_path(@transfer), alert: e.message
  end

  def set_transfer
    @transfer = InternalTransfer.find(params[:internal_transfer_id])
  end

  # find dentro da associação: uma remessa de outra transferência dá 404.
  def set_shipment
    @shipment = @transfer.shipments.find(params[:id])
  end

  def authorize_origin!
    return if current_user.admin? || current_user.can_access_location?(@shipment.origin_location.slug)

    redirect_to internal_transfer_path(@transfer), alert: 'Você não tem acesso à loja de origem desta remessa.'
  end

  def authorize_destination!
    return if current_user.admin? || current_user.can_access_location?(@transfer.destination_location.slug)

    redirect_to internal_transfer_path(@transfer), alert: 'Você não tem acesso à loja de destino desta transferência.'
  end

  # Cancelar: quem gerencia a origem (ou admin) sempre pode; quem pediu também pode, mas só
  # enquanto a remessa ainda está aberta (nada foi debitado no Shopify ainda).
  def authorize_cancel!
    return if current_user.admin? || current_user.can_access_location?(@shipment.origin_location.slug)
    return if @shipment.aberto? && @transfer.requested_by_id == current_user.id

    redirect_to internal_transfer_path(@transfer), alert: 'Você não pode cancelar esta remessa.'
  end
end
