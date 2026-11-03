# Naturezas de operação vinculadas a cada empresa: a mesma natureza (CFOP e tributação) pode ser
# usada por várias empresas, e na emissão escolhe-se uma das naturezas vinculadas à empresa.
# Começa vinculando cada natureza à empresa em que foi criada. Segura para rodar a qualquer momento.
class CreateCompanyOperationNatures < ActiveRecord::Migration[7.2]
  def up
    unless table_exists?(:company_operation_natures)
      create_table :company_operation_natures do |t|
        t.references :company, null: false, foreign_key: true
        t.references :operation_nature, null: false, foreign_key: true
        t.timestamps
        t.index %i[company_id operation_nature_id], unique: true, name: 'idx_company_operation_natures'
      end
    end
    execute <<~SQL.squish
      INSERT INTO company_operation_natures (company_id, operation_nature_id, created_at, updated_at)
      SELECT n.company_id, n.id, NOW(), NOW() FROM operation_natures n
      WHERE NOT EXISTS (SELECT 1 FROM company_operation_natures l WHERE l.company_id = n.company_id AND l.operation_nature_id = n.id)
    SQL
  end

  def down
    drop_table :company_operation_natures, if_exists: true
  end
end
