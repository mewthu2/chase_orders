class ChangeXmlNotaToLongTextInAttempts < ActiveRecord::Migration[7.0]
  def up
    change_column :attempts, :xml_nota, :text, limit: 4294967295
  end

  def down
    change_column :attempts, :xml_nota, :text
  end
end
