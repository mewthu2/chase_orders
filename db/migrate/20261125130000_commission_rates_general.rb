# O percentual de comissão é geral (um por pessoa), não mais mês a mês. A coluna month fica (nula, ignorada pelo
# model) para a migração poder rodar com o código antigo no ar; a tabela estava vazia em produção.
class CommissionRatesGeneral < ActiveRecord::Migration[8.1]
  def up
    change_column_null :commission_rates, :month, true
    remove_index :commission_rates, name: 'index_commission_rates_on_month_and_beneficiary', if_exists: true
    # Se houver mais de uma linha por pessoa, fica a do mês mais recente.
    execute <<~SQL
      DELETE r1 FROM commission_rates r1
      JOIN commission_rates r2 ON r1.beneficiary_type = r2.beneficiary_type AND r1.beneficiary_id = r2.beneficiary_id
        AND (r1.month < r2.month OR (r1.month = r2.month AND r1.id < r2.id))
    SQL
    add_index :commission_rates, %i[beneficiary_type beneficiary_id], unique: true, name: 'index_commission_rates_unique_beneficiary', if_not_exists: true
  end

  def down
    remove_index :commission_rates, name: 'index_commission_rates_unique_beneficiary', if_exists: true
  end
end
