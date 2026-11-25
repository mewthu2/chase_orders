require 'rubyXL'
require 'rubyXL/convenience_methods'

# Planilha (Excel) de uma HoneyTable: todas as colunas da tabela (as escondidas também; noexport: true fica de
# fora), com o texto que a tela mostra. Valor em dinheiro sai como número, datas como data.
class HoneyTableXlsx
  def self.call(table, rows, sheet_name: 'Lista') = new(table, rows, sheet_name).render

  def initialize(table, rows, sheet_name)
    @table = table
    @rows = rows
    @sheet_name = sheet_name
  end

  def render
    workbook = RubyXL::Workbook.new
    sheet = workbook[0]
    sheet.sheet_name = @sheet_name.first(31)
    cols = @table.cols.reject { |c| c[:noexport] }
    cols.each_with_index { |c, i| sheet.add_cell(0, i, c[:label].to_s).change_font_bold(true) }
    @rows.each_with_index do |row, r|
      cols.each_with_index do |c, i|
        value, format = cell(c, row[c[:k]])
        next if value.nil?

        cell = sheet.add_cell(r + 1, i, value)
        cell.set_number_format(format) if format
      end
    end
    cols.each_with_index { |c, i| sheet.change_column_width(i, width(c)) }
    workbook.stream.string
  end

  private

  def cell(col, value)
    case col[:t]
    when :money then value.nil? ? nil : [value.to_f.round(2), '#,##0.00']
    when :qty, :num then value.is_a?(Numeric) ? [value, nil] : [@table.cell_text(col, value), nil]
    when :d then value.respond_to?(:strftime) ? [value.to_date, 'dd/mm/yyyy'] : [value.to_s.presence, nil]
    # Hora local de Brasília, sem fuso (o Excel não guarda fuso).
    when :dt then value.respond_to?(:strftime) ? [DateTime.parse(value.in_time_zone.strftime('%Y-%m-%dT%H:%M:%S')), 'dd/mm/yyyy hh:mm'] : [value.to_s.presence, nil]
    else
      text = @table.cell_text(col, value).to_s.squish
      [text == '—' ? nil : text.presence, nil]
    end
  end

  def width(col)
    case col[:t]
    when :money, :d then 14
    when :dt then 17
    when :status then 18
    else [[col[:label].to_s.size + 4, 12].max, 40].min
    end
  end
end
