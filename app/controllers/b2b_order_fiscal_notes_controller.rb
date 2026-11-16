# Aba "Nota fiscal" da edição dos pedidos B2B (atacado, abastecimento e transferência B2C), no molde da
# Transferência Interna: emitir, enviar à SEFAZ/consultar e excluir a NF-e do pedido, em homologação ou em
# produção (no máximo uma ativa por ambiente). Empresa e natureza vêm das configurações de cada tela.
class B2bOrderFiscalNotesController < ApplicationController
  KIND_SCREENS = B2bOrdersController::KIND_SCREENS

  guard_screen(actions: { create: :edit, destroy: :edit, transmit: :edit, details: :edit }) { KIND_SCREENS.fetch(order.kind, :b2b_orders) }
  before_action :set_note, only: [:destroy, :transmit]

  def create
    environment = params[:environment].to_s
    return back_to_notes(alert: 'Escolha homologação ou produção.') unless FiscalNote.environments.key?(environment)

    setting = B2bSetting.current
    company = setting.issuer(order)
    nature = setting.nature_for(order)
    return back_to_notes(alert: "Escolha a empresa emissora e a natureza em #{B2bSetting.config_name(order)}.") unless company && nature

    CompanyOperationNature.find_or_create_by!(company:, operation_nature: nature)
    note = Nfe::Generator.call(order:, company:, nature:, environment:)
    if params[:draft].present?
      note.update!(status: :rascunho)
      return back_to_notes(notice: "NF-e nº #{note.number} gerada e não emitida. Confira o DANFE e o XML e clique em Emitir na SEFAZ.")
    end

    Nfe::Transmitter.call(note)
    back_to_notes(**result_flash(note))
  rescue Nfe::Generator::Error, Nfe::Transmitter::Error, ActiveRecord::RecordInvalid => e
    back_to_notes(alert: e.message)
  end

  # Dados da nota (informações complementares e transportadora): só enquanto não há nota de produção
  # autorizada, assinada ou sem resposta da SEFAZ. Valem para a próxima emissão (inclusive a do Log02).
  def details
    if (lock = order.nf_details_lock)
      return back_to_notes(alert: "A NF-e nº #{lock.number} está #{lock.status_label.downcase}: os dados da nota não mudam mais.")
    end

    attrs = params.require(:b2b_order).permit(:nf_additional_info, :nf_carrier_id, :nf_freight_mode).to_h
                  .transform_values { |v| v.to_s.strip.presence }
    attrs['nf_carrier_id'] = nil if attrs['nf_carrier_id'] && !Carrier.exists?(attrs['nf_carrier_id'])
    order.assign_attributes(attrs)
    order.valid?
    # Só os campos da nota: um pedido antigo com outro dado incompleto não pode travar a nota.
    errors = order.errors.select { |e| e.attribute.to_s.start_with?('nf_') }
    return back_to_notes(alert: errors.map(&:full_message).to_sentence) if errors.any?

    order.update_columns(attrs.merge('updated_at' => Time.current))
    back_to_notes(notice: 'Dados da nota salvos. Valem para a próxima emissão.')
  end

  # Assinada: envia de novo. Sem resposta (erro): consulta pela chave antes de qualquer outra coisa.
  def transmit
    @note.assinada! if @note.emittable?
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
