require 'test_helper'

class UserTest < ActiveSupport::TestCase
  test 'admin can access any screen regardless of profile permissions' do
    admin = User.create!(name: 'Admin', email: 'admin@example.com', password: 'password123') # salvo: admin? consulta os perfis no banco
    admin.profiles << Profile.find(Profile::ADMIN)
    assert admin.can_access_screen?('marketing_tasks')
  end

  test 'non-admin can access a screen only if one of their profiles grants it' do
    profile = Profile.create!(name: 'Perfil Sem Acesso')
    user = User.new(name: 'Teste', email: 'teste@example.com', password: 'password123')
    user.profiles << profile
    refute user.can_access_screen?('orders')

    profile.screen_permissions.create!(screen_key: 'orders')
    assert user.can_access_screen?('orders')
  end
end
