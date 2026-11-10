# IBS e CBS (reforma tributária) por natureza de operação. Os padrões são os que o emissor usava fixos
# (CST 000, cClassTrib 000001, IBS UF 0,10%, IBS município 0%, CBS 0,90%), então nenhuma nota muda.
class AddIbsCbsToOperationNatures < ActiveRecord::Migration[7.2]
  def change
    change_table :operation_natures, bulk: true do |t|
      t.string :ibs_cbs_mode, default: 'auto', null: false
      t.string :ibs_cbs_cst, default: '000', null: false
      t.string :ibs_cbs_class, default: '000001', null: false
      t.decimal :ibs_uf_rate, precision: 5, scale: 2, default: '0.1', null: false
      t.decimal :ibs_mun_rate, precision: 5, scale: 2, default: '0.0', null: false
      t.decimal :cbs_rate, precision: 5, scale: 2, default: '0.9', null: false
    end
  end
end
