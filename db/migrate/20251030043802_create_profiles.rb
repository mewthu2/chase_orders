class CreateProfiles < ActiveRecord::Migration[7.2]
  def change
    create_table :profiles do |t|
      t.string :name, null: false
      t.string :description
      t.boolean :active, default: true
      
      t.timestamps
    end
    
    add_index :profiles, :name, unique: true
    
    reversible do |dir|
      dir.up do
        Profile.create!([
          { id: 1, name: 'Admin', description: 'Administrador do sistema' },
          { id: 2, name: 'Gerente', description: 'Gerente' },
          { id: 3, name: 'Vendedor', description: 'Vendedor' },
          { id: 4, name: 'Estoquista', description: 'Estoquista' },
          { id: 5, name: 'Admin Marketing', description: 'Administrador de Marketing' },
          { id: 6, name: 'Agente Marketing', description: 'Agente de Marketing' }
        ])
      end
    end
  end
end
