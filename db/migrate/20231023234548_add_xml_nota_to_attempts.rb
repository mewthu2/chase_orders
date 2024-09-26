class AddXmlNotaToAttempts < ActiveRecord::Migration[7.0]
  def up
    add_column :attempts, :xml_nota, :text
    add_column :attempts, :xml_sended, :boolean, default: false
  end

  def down
    remove_column :attempts, :xml_sended
    remove_column :attempts, :xml_nota
  end
end
