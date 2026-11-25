module Finance
  # Perfil "Financeiro" com as telas da área, ligado ao usuário do financeiro (se ele já existir).
  module Setup
    PROFILE_NAME = 'Financeiro'.freeze
    USER_EMAIL = 'financeiro@chasebrasil.com'.freeze
    PERMISSIONS = { 'finance_orders' => 'VEP', 'consultants' => 'VCED', 'commissions' => 'VEP' }.freeze

    module_function

    def ensure_profile!
      profile = Profile.find_or_create_by!(name: PROFILE_NAME)
      PERMISSIONS.each do |key, letters|
        permission = ScreenPermission.find_or_initialize_by(profile_id: profile.id, screen_key: key)
        permission.update!(actions: letters) if permission.new_record? || permission.actions.blank?
      end
      user = User.find_by(email: USER_EMAIL)
      UserProfile.find_or_create_by!(user_id: user.id, profile_id: profile.id) if user
      profile
    end
  end
end
