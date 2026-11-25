# Um lado da colocação de uma nota de entrada: o que vai ao depósito do Correios Log02 (atacado) ou Log03
# (e-commerce), lido do CSV (sku, estoque), e a nota de remessa desse lado.
class StockPlacement < ApplicationRecord
  SIDES = { 'log02' => 'Entrada Correios Log02', 'log03' => 'Entrada Correios Log03' }.freeze

  belongs_to :stock_entry
  belongs_to :uploaded_by, class_name: 'User', optional: true
  belongs_to :divergence_acknowledged_by, class_name: 'User', optional: true
  has_many :fiscal_notes, dependent: :restrict_with_error

  validates :side, inclusion: { in: SIDES.keys }

  def label = SIDES[side]

  # { sku => quantidade }
  def quantities = Array(items).to_h { |sku, qty| [sku.to_s, qty.to_i] }
  def pieces = quantities.values.sum

  def notes_by_recent = fiscal_notes.order(id: :desc)
  def active_note = fiscal_notes.where(status: FiscalNote::ACTIVE_STATUSES).order(id: :desc).first
  def authorized_note = fiscal_notes.producao.autorizada.order(id: :desc).first
  def last_note = fiscal_notes.order(id: :desc).first

  SKU_HEADERS = %w[sku codigo cod produto referencia ref].freeze
  QTY_HEADERS = %w[estoque quantidade qtd qtde quant quantity qty].freeze

  # Lê o arquivo do lado (CSV ou Excel .xlsx) e devolve [[sku, qtd], ...] (SKU repetido soma) ou levanta
  # ArgumentError com a explicação. O cabeçalho é opcional: sem ele, a coluna A é o SKU e a B a quantidade;
  # com nomes conhecidos (sku/codigo e estoque/quantidade/qtd) na primeira linha, valem as colunas com esses nomes.
  def self.parse_file(data, filename: nil)
    rows = xlsx?(data, filename) ? xlsx_rows(data) : csv_rows(data)
    parse_rows(rows)
  end

  def self.parse_csv(text) = parse_file(text.to_s, filename: 'arquivo.csv')

  def self.xlsx?(data, filename)
    filename.to_s.downcase.end_with?('.xlsx') || data.to_s.byteslice(0, 2) == 'PK'
  end

  def self.xlsx_rows(data)
    require 'rubyXL'
    sheet = RubyXL::Parser.parse_buffer(data.to_s)[0]
    raise ArgumentError, 'A planilha está vazia.' unless sheet

    sheet.sheet_data.rows.map { |row| row ? row.cells.map { |c| c&.value } : [] }
  rescue Zip::Error, RubyXL::Error, NoMethodError, ArgumentError => e
    raise e if e.is_a?(ArgumentError) && e.message.start_with?('A planilha')

    raise ArgumentError, 'Não deu para ler a planilha. Salve como Excel (.xlsx) ou CSV e tente de novo.'
  end

  def self.csv_rows(text)
    text = text.to_s.dup.force_encoding('UTF-8')
    text = text.encode('UTF-8', 'ISO-8859-1') unless text.valid_encoding?
    lines = text.delete_prefix("\uFEFF").lines.map(&:strip).reject(&:empty?)
    return [] if lines.empty?

    first = lines.first
    sep = if first.include?("\t") then "\t"
          elsif first.count(';') >= first.count(',') && first.include?(';') then ';'
          elsif first.include?(',') then ','
          else ';'
          end
    lines.map { |line| line.split(sep).map { |c| c.strip.delete('"') } }
  end

  def self.parse_rows(rows)
    rows = rows.map { |r| Array(r).map { |c| cell_text(c) } }.reject { |r| r.all?(&:empty?) }
    raise ArgumentError, 'O arquivo está vazio.' if rows.empty?

    header = rows.first.map { |h| I18n.transliterate(h).downcase.strip }
    sku_col = header.index { |h| SKU_HEADERS.include?(h) }
    qty_col = header.index { |h| QTY_HEADERS.include?(h) }
    if sku_col && qty_col
      rows = rows.drop(1)
    else
      # Sem cabeçalho reconhecido: A = SKU, B = quantidade. Se a primeira linha não tem número na B, é cabeçalho.
      sku_col = 0
      qty_col = 1
      rows = rows.drop(1) unless quantity?(rows.first[1])
    end

    totals = Hash.new(0)
    rows.each_with_index do |cells, i|
      sku = cells[sku_col].to_s.strip
      next if sku.empty?

      raw = cells[qty_col].to_s.strip
      raise ArgumentError, "Linha #{i + 1}: a quantidade \"#{raw}\" do SKU #{sku} não é um número inteiro." unless quantity?(raw)

      totals[sku.upcase] += raw.sub(/[.,]0+\z/, '').to_i
    end
    totals.reject! { |_, q| q.zero? }
    raise ArgumentError, 'Nenhum SKU com quantidade no arquivo (coluna A: SKU, coluna B: quantidade).' if totals.empty?

    totals.to_a
  end

  def self.quantity?(value) = value.to_s.strip.match?(/\A\d+([.,]0+)?\z/)

  # Célula do Excel: número inteiro vira "12" (não "12.0"); o resto, texto.
  def self.cell_text(value)
    case value
    when Float then value == value.floor ? value.to_i.to_s : value.to_s
    when nil then ''
    else value.to_s.strip
    end
  end
end
