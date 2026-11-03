# Cada loja passa a ter a empresa (CNPJ) que emite e recebe as notas de transferência entre lojas.
class AddCompanyToLocations < ActiveRecord::Migration[7.2]
  def change
    add_reference :locations, :company, foreign_key: true, null: true, if_not_exists: true
  end
end
