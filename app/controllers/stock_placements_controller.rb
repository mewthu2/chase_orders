# Logística › Colocação de estoque: cada nota de entrada é dividida entre o depósito do Correios Log02 (atacado)
# e o Log03 (e-commerce) por um CSV (sku, estoque) de cada lado. Quando a soma dos dois bate 100% com a nota de
# entrada, cada lado gera a sua nota de remessa (Nfe::PlacementGenerator), emitida na SEFAZ pelo botão Emitir.
# O painel de uma entrada abre num modal (turbo-frame "placement_panel"); sem o frame, abre como página.
class StockPlacementsController < ApplicationController
  guard_screen :stock_placements, actions: { upload: :create, remove: :create, generate: :execute, transmit: :execute,
                                             discard_note: :execute, note_xml: :export, note_danfe: :export }
  before_action :set_entry, except: :index
  before_action :set_side, only: %i[upload remove generate]
  before_action :set_note, only: %i[transmit discard_note note_xml note_danfe]

  def index
    @entries = StockEntry.includes(:company, :items, placements: :fiscal_notes).recent.to_a
  end

  def show
    render layout: false if turbo_frame_request?
  end

  def upload
    placement = @entry.placement(@side)
    return back_to_panel(alert: "O #{StockPlacement::SIDES[@side]} já tem nota de remessa: exclua ou cancele a nota para trocar o CSV.") if placement&.active_note

    file = params[:csv]
    return back_to_panel(alert: 'Escolha o arquivo CSV.') unless file.respond_to?(:read)
    return back_to_panel(alert: 'O arquivo passa de 2 MB.') if file.size > 2.megabytes

    items = StockPlacement.parse_csv(file.read)
    placement ||= @entry.placements.build(side: @side)
    placement.update!(items: items, csv_filename: file.original_filename.to_s.first(200), uploaded_by: current_user)
    @entry.placements.reset
    msg = "#{placement.label}: #{items.size} SKUs, #{placement.pieces} peças."
    msg += ' A conferência bateu: já dá para gerar as notas de remessa.' if @entry.balanced?
    back_to_panel(notice: msg)
  rescue ArgumentError => e
    back_to_panel(alert: "CSV do #{StockPlacement::SIDES[@side]}: #{e.message}")
  end

  def remove
    placement = @entry.placement(@side)
    return back_to_panel(alert: 'Este lado não tem CSV.') unless placement
    return back_to_panel(alert: 'Este lado já tem nota de remessa: exclua ou cancele a nota antes.') if placement.active_note

    placement.fiscal_notes.update_all(stock_placement_id: nil)
    placement.destroy!
    back_to_panel(notice: "CSV do #{StockPlacement::SIDES[@side]} retirado.")
  end

  def generate
    placement = @entry.placement(@side) or return back_to_panel(alert: 'Suba o CSV deste lado primeiro.')
    acknowledged = params[:ciente] == '1' ? current_user : nil
    note = Nfe::PlacementGenerator.call(placement: placement, environment: params[:environment], acknowledged_by: acknowledged)
    back_to_panel(notice: "NF-e de remessa nº #{note.number} (#{placement.label}) gerada e não emitida. Confira o DANFE e clique em Emitir na SEFAZ.")
  rescue Nfe::PlacementGenerator::Error => e
    back_to_panel(alert: e.message)
  end

  def transmit
    return back_to_panel(alert: @note.company.production_block_message) if @note.production_blocked? && !@note.erro?

    @note.assinada! if @note.emittable?
    Nfe::Transmitter.call(@note, consult: @note.erro?)
    @note.reload
    if @note.autorizada?
      back_to_panel(notice: "NF-e de remessa nº #{@note.number} autorizada pela SEFAZ.")
    else
      back_to_panel(alert: "NF-e nº #{@note.number}: #{FiscalNote::STATUS_LABELS[@note.status]}. #{@note.sefaz_message || @note.error_message}".strip)
    end
  rescue Nfe::Transmitter::Error => e
    back_to_panel(alert: e.message)
  end

  def discard_note
    reason = @note.undeletable_reason
    return back_to_panel(alert: reason) if reason

    number = @note.number
    @note.discard!
    back_to_panel(notice: "NF-e de remessa nº #{number} excluída.")
  end

  def note_xml
    return back_to_panel(alert: 'A nota não tem XML.') unless @note.xml_available?

    send_data @note.xml.download, filename: "NFe#{@note.access_key}.xml", type: 'application/xml', disposition: 'attachment'
  end

  def note_danfe
    return back_to_panel(alert: 'A nota não tem XML.') unless @note.xml_available?

    danfe = Nfe::Danfe.new(@note.xml.download, cancelled: @note.cancelada?)
    send_data danfe.render, filename: danfe.filename, type: 'application/pdf', disposition: 'attachment'
  end

  private

  def set_entry
    @entry = StockEntry.includes(:items, placements: :fiscal_notes).find(params[:id])
  end

  def set_side
    @side = params[:side].to_s
    raise ActionController::RoutingError, 'lado inválido' unless StockPlacement::SIDES.key?(@side)
  end

  def set_note
    @note = FiscalNote.joins(:stock_placement).where(stock_placements: { stock_entry_id: @entry.id }).find(params[:note_id])
  end

  def back_to_panel(**flash_args)
    redirect_to stock_placement_path(@entry), **flash_args
  end
end
