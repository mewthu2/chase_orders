# Como a pessoa arrumou as colunas de uma tabela: columns = [["coluna", true/false], ...] na ordem escolhida.
# table_key = rota da tela + id da tabela (HoneyPageHelper#hc_pg_layout_key).
class TableColumnPreference < ApplicationRecord
  MAX_COLUMNS = 80

  belongs_to :user

  validates :table_key, presence: true, length: { maximum: 191 }

  # Aceita [{ "k" => "valor", "on" => true }, ...] ou [["valor", true], ...] e guarda só pares válidos, sem repetir.
  def self.clean(columns)
    Array(columns).first(MAX_COLUMNS).filter_map do |c|
      key, on = c.is_a?(Array) ? c : [c['k'] || c[:k], c.key?('on') ? c['on'] : c[:on]]
      key = key.to_s
      [key, ActiveModel::Type::Boolean.new.cast(on) == true] if key.match?(/\A[A-Za-z0-9_]{1,60}\z/)
    end.uniq(&:first)
  end
end
