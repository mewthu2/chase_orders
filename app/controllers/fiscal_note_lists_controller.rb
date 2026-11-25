# Notas fiscais de uma área só, por mês: Atacado (pedidos de venda, na área Financeiro, com o status do pedido e
# as parcelas do boleto) e Logística (abastecimento das lojas e transferência B2B ⇄ B2C, com as notas de remessa). Sem o interruptor de homologação/produção da tela de
# Notas Fiscais do Adm. O ZIP leva o XML das notas autorizadas e canceladas (com o evento de cancelamento)
# do filtro atual ou só das selecionadas.
class FiscalNoteListsController < ApplicationController
  LISTS = {
    'atacado' => { screens: [:finance_orders], kinds: %w[sale], title: 'Notas Fiscais',
                   subtitle: 'NF-e dos pedidos de atacado, mês a mês, com o status do pedido e a baixa das parcelas do boleto.',
                   icon: 'fas fa-file-invoice-dollar' },
    'logistica' => { screens: %i[store_supply b2b_transfers], kinds: %w[stock_transfer b2c_transfer], title: 'Notas Fiscais da Logística',
                     subtitle: 'NF-e do abastecimento das lojas e das transferências B2B ⇄ B2C, mês a mês.', icon: 'fas fa-truck-fast' }
  }.freeze
  ZIP_STATUSES = %w[autorizada cancelada].freeze
  MAX_ZIP_NOTES = 2000

  guard_screen(actions: { xmls: :export, xml: :export, danfe: :export, export: :export }) { list[:screens] }
  helper_method :list, :list_key

  def index
    @scope = scope
  end

  def xmls
    notes = helpers.fiscal_note_list_table(list_key, scope).filtered
    ids = Array(params[:ids]).map(&:to_i).select(&:positive?)
    notes = notes.where(id: ids) if ids.any?
    notes = notes.where(status: ZIP_STATUSES).reorder(:number).limit(MAX_ZIP_NOTES + 1)
                 .includes(:company, xml_attachment: :blob, cancel_xml_attachment: :blob).to_a
    return redirect_back_or_to(list_path, alert: 'Nenhuma nota autorizada ou cancelada com XML neste filtro.') if notes.none?(&:xml_available?)
    return redirect_back_or_to(list_path, alert: "São mais de #{MAX_ZIP_NOTES} notas: escolha um mês, um período menor ou filtre mais.") if notes.size > MAX_ZIP_NOTES

    send_data Nfe::XmlZip.call(notes), filename: zip_filename(ids.any?), type: 'application/zip', disposition: 'attachment'
  end

  # Planilha (Excel) com todas as notas que o filtro mostra (todas as páginas); sem filtro, todas do mês/ambiente.
  MAX_EXPORT_ROWS = 20_000

  def export
    table = helpers.fiscal_note_list_table(list_key, scope)
    return redirect_back_or_to(list_path, alert: "São mais de #{MAX_EXPORT_ROWS} notas: filtre mais.") if table.total > MAX_EXPORT_ROWS

    send_data HoneyTableXlsx.call(table, table.all_rows(limit: MAX_EXPORT_ROWS), sheet_name: 'Notas fiscais'),
              filename: zip_filename(false).sub(/\.zip\z/, '.xlsx'), disposition: 'attachment',
              type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
  end

  # XML e DANFE de uma nota da lista, com a permissão da própria tela (sem precisar da tela Notas Fiscais do Adm).
  def xml
    note = list_note
    return redirect_to(list_path, alert: 'Esta nota ainda não tem XML gerado.') unless note.xml_available?

    send_data note.xml.download, filename: "NFe#{note.access_key}.xml", type: 'application/xml', disposition: 'attachment'
  end

  def danfe
    note = list_note
    return redirect_to(list_path, alert: 'Esta nota ainda não tem XML gerado.') unless note.xml_available?

    danfe = Nfe::Danfe.new(note.xml.download, cancelled: note.cancelada?)
    send_data danfe.render, filename: danfe.filename, type: 'application/pdf', disposition: 'attachment'
  end

  private

  def list_note
    FiscalNote.joins(:b2b_order).where(b2b_orders: { kind: B2bOrder.kinds.values_at(*list[:kinds]) }).find(params[:id])
  end

  def list_key = LISTS.key?(params[:list]) ? params[:list] : 'atacado'
  def list = LISTS.fetch(list_key)
  def list_path = list_key == 'atacado' ? wholesale_fiscal_notes_path : logistics_fiscal_notes_path

  # Notas da área no mês escolhido (o atual quando não há mês na URL; "todos" tira o mês) e no ambiente
  # escolhido (produção quando não há ambiente na URL).
  def scope
    out = FiscalNote.joins(:b2b_order).where(b2b_orders: { kind: B2bOrder.kinds.values_at(*list[:kinds]) })
                    .includes(:company, :nature, b2b_order: [:client, :transfer_location, { payments: :paid_by }]).recent
    out = out.where(environment: params[:amb] == 'homologacao' ? :homologacao : :producao) unless params[:amb] == 'todos'
    range = month_range
    range ? out.where('COALESCE(fiscal_notes.issued_at, fiscal_notes.created_at) BETWEEN ? AND ?', range.begin, range.end) : out
  end

  # O mês do filtro ou o intervalo de dias escolhido no calendário.
  def month_range
    return nil if params[:mes] == 'todos'
    return HoneyTable.parse_range(params[:mes]) if HoneyTable.parse_range(params[:mes])

    month = HoneyTable.parse_month(params[:mes]) || Date.current.beginning_of_month
    month.in_time_zone.beginning_of_month..month.in_time_zone.end_of_month
  end

  def zip_filename(selected)
    range = HoneyTable.parse_range(params[:mes])
    month = if params[:mes] == 'todos' then 'todos-os-meses'
            elsif range then "#{range.begin.to_date.iso8601}_a_#{range.end.to_date.iso8601}"
            else (HoneyTable.parse_month(params[:mes]) || Date.current).strftime('%Y-%m')
            end
    "notas-#{list_key}-#{month}#{'-selecionadas' if selected}.zip"
  end
end
