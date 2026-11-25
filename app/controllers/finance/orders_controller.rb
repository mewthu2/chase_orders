require 'rubyXL'
require 'rubyXL/convenience_methods'

module Finance
  # Recebimentos dos pedidos de atacado: uma linha por parcela de boleto e uma por pedido PIX/cartão (pago na criação).
  # O mês filtra o vencimento (PIX/cartão: a data do pedido); parcelas vencidas de meses anteriores sempre aparecem.
  # A planilha e o ZIP de XML levam as linhas marcadas (keys) ou, sem keys, tudo o que o filtro da URL mostra.
  class OrdersController < ApplicationController
    guard_screen :finance_orders, actions: { export: :export, xmls: :export }

    ORDER_INCLUDES = %i[client user consultant b2b_order_items payments].freeze

    # Consultor (quem recomendou) do pedido: escolher um cadastrado, digitar um nome livre ou tirar.
    def edit
      @order = B2bOrder.sale.find(params[:id])
      @consultants = Consultant.active.ordered.to_a
      @consultants |= [@order.consultant] if @order.consultant
    end

    def update
      order = B2bOrder.sale.find(params[:id])
      name = params[:name].to_s.squish
      consultant = if params[:remove].present? then nil
                   elsif params[:consultant_id].present? then Consultant.find(params[:consultant_id])
                   elsif name.present? then Consultant.find_by('LOWER(name) = ?', name.downcase)
                   end
      order.update_columns(consultant_id: consultant&.id, salesperson_name: params[:remove].present? ? nil : (consultant&.name || name.presence),
                           updated_at: Time.current)
      label = order.consultant_label
      redirect_to params[:return_to].to_s.start_with?('/financeiro/pedidos') ? params[:return_to] : finance_orders_path,
                  notice: label ? "Pedido ##{order.id}: consultor #{label}." : "Pedido ##{order.id} ficou sem consultor."
    end

    def index
      @month = params[:mes].presence || Date.current.strftime('%Y-%m')
      @receivables = receivables
    end

    def export
      rows = selected_rows
      return redirect_back_or_to(finance_orders_path, alert: 'Nenhuma linha selecionada.') if rows.empty?

      send_data spreadsheet(rows), filename: "recebimentos-atacado-#{file_suffix}.xlsx", disposition: 'attachment',
                                   type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
    end

    # XML das NF-e (produção, autorizadas e canceladas) dos pedidos das linhas.
    def xmls
      order_ids = selected_rows.map { |r| r[:order].id }.uniq
      notes = FiscalNote.producao.where(b2b_order_id: order_ids, status: FiscalNoteListsController::ZIP_STATUSES).reorder(:number)
                        .limit(FiscalNoteListsController::MAX_ZIP_NOTES + 1).includes(:company, xml_attachment: :blob, cancel_xml_attachment: :blob).to_a
      return redirect_back_or_to(finance_orders_path, alert: 'Nenhum pedido selecionado tem NF-e autorizada ou cancelada com XML.') if notes.none?(&:xml_available?)
      return redirect_back_or_to(finance_orders_path, alert: "São mais de #{FiscalNoteListsController::MAX_ZIP_NOTES} notas: filtre mais.") if notes.size > FiscalNoteListsController::MAX_ZIP_NOTES

      send_data Nfe::XmlZip.call(notes), filename: "notas-recebimentos-atacado-#{file_suffix}.zip", type: 'application/zip', disposition: 'attachment'
    end

    private

    def receivables
      @month = params[:mes].presence || Date.current.strftime('%Y-%m')
      range = date_range
      orders = B2bOrder.sale.where.not(status: :cancelado)

      created = orders.where(payment_method: %w[pix cartao])
      created = created.where(created_at: range.begin.beginning_of_day..range.end.end_of_day) if range
      payments = B2bOrderPayment.joins(:b2b_order).merge(orders)
      payments = payments.where(due_date: range).or(payments.where(paid_at: nil, due_date: ...range.begin)) if range

      list = created.includes(*ORDER_INCLUDES).filter_map do |order|
        amount = order.creation_paid_amount
        next unless amount.positive?

        { order: order, payment: nil, due: order.created_at.to_date, amount: amount, paid_at: order.created_at.to_date }
      end
      list + payments.includes(:paid_by, b2b_order: ORDER_INCLUDES).map do |p|
        { order: p.b2b_order, payment: p, due: p.due_date, amount: p.amount, paid_at: p.paid_at }
      end
    end

    # Linhas do filtro da URL; com keys ("12,o34": parcela 12 e o PIX/cartão do pedido 34), só essas.
    def selected_rows
      rows = helpers.finance_receivables_table(receivables).matching
      keys = params[:keys].to_s.split(',').map(&:strip).reject(&:empty?)
      params[:all] == '1' ? rows : rows.select { |r| keys.include?(r[:id]) }
    end

    def spreadsheet(rows)
      workbook = RubyXL::Workbook.new
      sheet = workbook[0]
      sheet.sheet_name = 'Recebimentos'
      statuses = helpers.b2b_order_statuses
      headers = ['Pedido', 'Cliente', 'Parcela', 'Forma de pagamento', 'Consultor', 'Vendedor', 'Valor', 'Vencimento', 'Pago em', 'Baixa por',
                 'Situação', 'Status do pedido']
      headers.each_with_index { |h, c| sheet.add_cell(0, c, h).change_font_bold(true) }
      rows.each_with_index do |r, i|
        values = [r[:num], r[:cliente], r[:parcela], r[:forma], r[:consultor_txt].presence || '—', r[:digitador], r[:valor].round(2), r[:venc], r[:pago_em],
                  r[:quem], FinanceOrdersHelper::FINANCE_PAYMENT_STATUSES.dig(r[:st], 0), statuses.dig(r[:ost], 0) || r[:ost]]
        values.each_with_index do |v, c|
          cell = sheet.add_cell(i + 1, c, v)
          cell.set_number_format('dd/mm/yyyy') if v.is_a?(Date)
        end
        sheet[i + 1][6].set_number_format('#,##0.00')
      end
      sheet.add_cell(rows.size + 1, 5, 'Total').change_font_bold(true)
      sheet.add_cell(rows.size + 1, 6, rows.sum { |r| r[:valor] }.round(2)).tap { |c| c.change_font_bold(true); c.set_number_format('#,##0.00') }
      [10, 40, 9, 28, 24, 20, 14, 12, 12, 20, 11, 18].each_with_index { |w, c| sheet.change_column_width(c, w) }
      workbook.stream.string
    end

    def file_suffix
      [params[:mes] == 'todos' ? 'todos-os-meses' : (params[:mes].presence || Date.current.strftime('%Y-%m')).tr('.', '_'),
       ('selecionados' unless params[:all] == '1')].compact.join('-')
    end

    # Datas do filtro: um mês, um intervalo do calendário ou nil ("todos").
    def date_range
      return nil if @month == 'todos'
      if (range = HoneyTable.parse_range(@month))
        return range.begin.to_date..range.end.to_date
      end

      month = HoneyTable.parse_month(@month) || Date.current.beginning_of_month
      month..month.end_of_month
    end
  end
end
