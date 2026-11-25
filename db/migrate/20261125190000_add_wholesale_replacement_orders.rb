# Pedido de devolução do atacado: peças devolvidas (ex.: com defeito) que voltam ao lojista como mercadoria nova em
# substituição, num pedido vinculado ao original, sem cobrança. Segue o Log02/Correios como uma venda, mas a NF-e
# sai pela empresa e natureza da configuração de devolução, com a chave da nota original e a da devolução.
class AddWholesaleReplacementOrders < ActiveRecord::Migration[8.1]
  def up
    add_column :b2b_orders, :replacement, :boolean, null: false, default: false unless column_exists?(:b2b_orders, :replacement)
    add_reference :b2b_orders, :replacement_of, foreign_key: { to_table: :b2b_orders, on_delete: :nullify } unless column_exists?(:b2b_orders, :replacement_of_id)
    add_column :b2b_orders, :original_nfe_key, :string, limit: 44 unless column_exists?(:b2b_orders, :original_nfe_key)
    add_column :b2b_orders, :return_nfe_key, :string, limit: 44 unless column_exists?(:b2b_orders, :return_nfe_key)
    add_reference :b2b_settings, :return_issuer_company, foreign_key: { to_table: :companies, on_delete: :nullify } unless column_exists?(:b2b_settings, :return_issuer_company_id)
    add_reference :b2b_settings, :return_nature, foreign_key: { to_table: :operation_natures, on_delete: :nullify } unless column_exists?(:b2b_settings, :return_nature_id)

    # Padrão pedido: Chase 02 Contagem com a natureza "mercadoria em substituição por defeito".
    company = select_value("SELECT id FROM companies WHERE cnpj = '25405327000255' LIMIT 1")
    nature = select_value("SELECT id FROM operation_natures WHERE id = 7 AND description LIKE '%SUBSTITUI%' LIMIT 1")
    if company || nature
      execute "UPDATE b2b_settings SET return_issuer_company_id = COALESCE(return_issuer_company_id, #{company.to_i.nonzero? || 'NULL'}), " \
              "return_nature_id = COALESCE(return_nature_id, #{nature.to_i.nonzero? || 'NULL'})"
    end

    # Caso excepcional: o pedido 108 repõe peças com defeito de uma venda que está no Tiny (NF-e 15712).
    execute <<~SQL.squish
      UPDATE b2b_orders SET replacement = TRUE, original_nfe_key = '31261125405327000255550010000157121030566741'
      WHERE id = 108 AND kind = 0 AND client_id = 211 AND original_nfe_key IS NULL
    SQL
  end

  def down
    remove_reference :b2b_settings, :return_nature, foreign_key: { to_table: :operation_natures }
    remove_reference :b2b_settings, :return_issuer_company, foreign_key: { to_table: :companies }
    remove_column :b2b_orders, :return_nfe_key
    remove_column :b2b_orders, :original_nfe_key
    remove_reference :b2b_orders, :replacement_of, foreign_key: { to_table: :b2b_orders }
    remove_column :b2b_orders, :replacement
  end
end
