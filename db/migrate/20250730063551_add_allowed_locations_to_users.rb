class AddAllowedLocationsToUsers < ActiveRecord::Migration[7.0]
  def change
    unless column_exists?(:users, :allowed_locations)
      add_column :users, :allowed_locations, :json
    end

    reversible do |dir|
      dir.up do
        User.reset_column_information
        User.where(allowed_locations: nil).update_all(allowed_locations: '[]')
      end
    end
  end
end
