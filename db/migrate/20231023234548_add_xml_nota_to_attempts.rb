class AddXmlNotaToAttempts < ActiveRecord::Migration[7.0]
  def change
    add_column :attempts, :xml_nota, :text, after: :params
    add_column :attempts, :xml_sended, :boolean, default: :false, after: :xml_nota
  end
end
