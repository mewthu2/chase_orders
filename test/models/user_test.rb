require 'test_helper'

class UserTest < ActiveSupport::TestCase
  test 'profile photo accepts JPEG PNG and WEBP up to 5 MB' do
    user = User.new(name: 'Foto', email: 'foto@example.com', password: 'password123')

    User::AVATAR_CONTENT_TYPES.each do |content_type|
      user.avatar = { io: StringIO.new('image'), filename: 'avatar', content_type: content_type, identify: false }
      assert user.valid?, user.errors.full_messages.join(', ')
      user.avatar.blob.byte_size = User::AVATAR_MAX_SIZE
      assert user.valid?, user.errors.full_messages.join(', ')
    end
  end

  test 'profile photo rejects unsupported types and oversized files' do
    user = User.new(name: 'Foto', email: 'foto@example.com', password: 'password123')
    user.avatar = { io: StringIO.new('<svg></svg>'), filename: 'avatar.svg', content_type: 'image/svg+xml' }
    refute user.valid?
    assert_includes user.errors[:avatar], 'deve ser uma imagem JPG, PNG ou WEBP'

    user.avatar = { io: StringIO.new('image'), filename: 'avatar.png', content_type: 'image/png', identify: false }
    user.avatar.blob.byte_size = User::AVATAR_MAX_SIZE + 1
    refute user.valid?
    assert_includes user.errors[:avatar], 'deve ter no máximo 5 MB'
  end

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
