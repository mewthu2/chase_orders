class CreateTicketSectors < ActiveRecord::Migration[7.2]
  # Setores agrupam as responsabilidades de chamados. Cada perfil libera os setores que seus
  # usuários enxergam (admin vê todos): onde podem abrir chamado e quais chamados acompanham.
  def change
    create_table :ticket_sectors do |t|
      t.string :name, null: false
      t.text :description
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :ticket_sectors, :name, unique: true

    create_table :profile_ticket_sectors do |t|
      t.references :profile, null: false, foreign_key: true
      t.references :ticket_sector, null: false, foreign_key: true
      t.timestamps
    end
    add_index :profile_ticket_sectors, [:profile_id, :ticket_sector_id], unique: true, name: 'index_profile_ticket_sectors_on_profile_and_sector'

    # nulo no banco para não quebrar responsabilidades que já existam; o model exige o setor
    add_reference :ticket_responsabilities, :ticket_sector, foreign_key: true
  end
end
