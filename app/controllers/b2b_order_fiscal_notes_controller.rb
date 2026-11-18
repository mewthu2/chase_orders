# Aba "Nota fiscal" da edição dos pedidos B2B (atacado, abastecimento e transferência B2C), no molde da
# Transferência Interna: emitir, enviar à SEFAZ/consultar e excluir a NF-e do pedido, em homologação ou em
# produção (no máximo uma ativa por ambiente). Empresa e natureza vêm das configurações de cada tela.
class B2bOrderFiscalNotesController < ApplicationController
  KIND_SCREENS = B2bOrdersController::KIND_SCREENS
  NO_REMESSA = 'Só o abastecimento das lojas e a transferência B2C → B2B têm nota de remessa.'.freeze

  guard_screen(actions: { create: :edit, destroy: :edit, transmit: :edit, details: :edit, remessa_recipient: :edit }) { KIND_SCREENS.fetch(order.kind, :b2b_orders) }
  before_action :set_note, only: [:destroy, :transmit]

  def create
    environment = params[:environment].to_s
    return back_to_notes(alert: 'Escolha homologação ou produção.') unless FiscalNote.environments.key?(environment)

    setting = B2bSetting.current
    remessa = params[:role] == 'remessa'
    return back_to_notes(alert: NO_REMESSA) if remessa && !order.remessa_note?

    company = remessa ? setting.remessa_issuer(order) : setting.issuer(order)
    nature = remessa ? setting.remessa_nature_for(order) : setting.nature_for(order)
    unless company && nature
      return back_to_notes(alert: remessa ? "Escolha a empresa e a natureza da nota de remessa em #{B2bSetting.remessa_config_name(order)}." : "Escolha a empresa emissora e a natureza em #{B2bSetting.config_name(order)}.")
    end

    return back_to_notes(alert: company.production_block_message) if environment == 'producao' && company.homologacao?

    CompanyOperationNature.find_or_create_by!(company:, operation_nature: nature)
    note = Nfe::Generator.call(order:, company:, nature:, environment:, role: (remessa ? 'remessa' : nil))
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

  # Destinatário da nota de remessa só deste pedido. "Voltar ao padrão" limpa e passa a valer o das
  # configurações do tipo do pedido. Não mexe no cadastro de ninguém.
  def remessa_recipient
    return back_to_notes(alert: NO_REMESSA) unless order.remessa_note?

    if params[:reset].present?
      order.update_columns(remessa_recipient: nil, updated_at: Time.current)
      return back_to_notes(notice: 'Destinatário da remessa voltou ao padrão das configurações.')
    end

    data = B2bSetting.normalize_recipient(params.require(:remessa_recipient).permit(*B2bSetting::REMESSA_RECIPIENT_FIELDS).to_h)
    order.update_columns(remessa_recipient: data, updated_at: Time.current)
    back_to_notes(notice: 'Destinatário da remessa salvo só para este pedido. Vale para a próxima nota de remessa.')
  end

  # Assinada: envia de novo. Sem resposta (erro): consulta pela chave antes de qualquer outra coisa.
  def transmit
    return back_to_notes(alert: @note.company.production_block_message) if @note.production_blocked? && !@note.erro?

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
