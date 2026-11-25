# Logística › Notas Fiscais de Entrada: sobe o XML da NF-e de compra e guarda a nota com os itens
# (StockEntries::XmlImport). Base da Colocação de estoque. Não mexe em estoque nenhum.
class StockEntriesController < ApplicationController
  guard_screen :stock_entries, actions: { xml: :export }

  def index
    @entries = StockEntry.includes(:company, :items, placements: :fiscal_notes).recent.to_a
  end

  def show
    @entry = StockEntry.includes(:items, placements: :fiscal_notes).find(params[:id])
  end

  def create
    file = params[:xml]
    return redirect_to(stock_entries_path, alert: 'Escolha o arquivo XML da nota.') unless file.respond_to?(:read)
    return redirect_to(stock_entries_path, alert: 'O arquivo passa de 5 MB.') if file.size > 5.megabytes

    entry = StockEntries::XmlImport.call(file, user: current_user)
    unknown = entry.items.map(&:sku).uniq - Product.where(sku: entry.items.map(&:sku)).pluck(:sku)
    notice = "NF-e nº #{entry.number} de #{entry.supplier_name} importada: #{entry.items.size} itens, #{entry.pieces} peças."
    notice += " Atenção: #{unknown.size} SKU(s) não estão no cadastro de produtos." if unknown.any?
    redirect_to stock_entry_path(entry), notice: notice
  rescue StockEntries::XmlImport::Error => e
    redirect_to stock_entries_path, alert: e.message
  end

  def destroy
    entry = StockEntry.find(params[:id])
    return redirect_to(stock_entry_path(entry), alert: 'Esta entrada já tem nota de remessa gerada: exclua ou cancele as notas antes.') if entry.locked?

    entry.placements.each { |p| p.fiscal_notes.where.not(status: FiscalNote::ACTIVE_STATUSES).update_all(stock_placement_id: nil) }
    entry.destroy!
    redirect_to stock_entries_path, notice: "NF-e de entrada nº #{entry.number} excluída."
  end

  def xml
    entry = StockEntry.find(params[:id])
    return redirect_to(stock_entry_path(entry), alert: 'Esta entrada não tem o XML guardado.') unless entry.xml.attached?

    send_data entry.xml.download, filename: "NFe#{entry.access_key}.xml", type: 'application/xml', disposition: 'attachment'
  end
end
