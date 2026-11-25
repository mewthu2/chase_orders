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

  # Lê o CSV: colunas sku e estoque (também aceita quantidade/qtd), separador ; ou , e cabeçalho em qualquer
  # caixa. SKU repetido soma. Devolve [[sku, qtd], ...] ou levanta ArgumentError com a explicação.
  def self.parse_csv(text)
    text = text.to_s.dup.force_encoding('UTF-8')
    text = text.encode('UTF-8', 'ISO-8859-1') unless text.valid_encoding?
    text = text.delete_prefix("﻿")
    lines = text.lines.map(&:strip).reject(&:empty?)
    raise ArgumentError, 'O arquivo está vazio.' if lines.empty?

    sep = lines.first.count(';') >= lines.first.count(',') ? ';' : ','
    sep = "\t" if lines.first.include?("\t") && !lines.first.include?(sep)
    header = lines.first.split(sep).map { |h| I18n.transliterate(h.to_s.strip.delete('"')).downcase }
    sku_col = header.index { |h| %w[sku codigo cod].include?(h) }
    qty_col = header.index { |h| %w[estoque quantidade qtd qtde quantity].include?(h) }
    raise ArgumentError, 'O CSV precisa das colunas sku e estoque na primeira linha.' unless sku_col && qty_col

    totals = Hash.new(0)
    lines.drop(1).each_with_index do |line, i|
      cells = line.split(sep).map { |c| c.strip.delete('"') }
      sku = cells[sku_col].to_s.strip
      next if sku.empty?

      raw = cells[qty_col].to_s.strip.sub(/[.,]0+\z/, '')
      raise ArgumentError, "Linha #{i + 2}: estoque \"#{cells[qty_col]}\" do SKU #{sku} não é um número inteiro." unless raw.match?(/\A\d+\z/)

      totals[sku.upcase] += raw.to_i
    end
    raise ArgumentError, 'Nenhum SKU com estoque no arquivo.' if totals.empty?

    totals.reject { |_, q| q.zero? }.to_a
  end
end
