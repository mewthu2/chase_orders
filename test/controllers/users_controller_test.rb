require 'test_helper'

class UsersControllerTest < ActionDispatch::IntegrationTest
  test 'admin can access the users index' do
    admin = User.create!(name: 'Admin', email: 'admin@example.com', password: 'password123')
    admin.profiles << Profile.find(Profile::ADMIN)
    sign_in admin

    get users_path
    assert_response :success
  end

  test 'a user whose profile has no users_management access is redirected' do
    profile = Profile.create!(name: 'Sem Acesso')
    user = User.create!(name: 'Sem Acesso', email: 'sem_acesso@example.com', password: 'password123')
    user.profiles << profile
    sign_in user

    get users_path
    assert_redirected_to root_path
  end

  test 'a non-admin can still edit their own record' do
    profile = Profile.create!(name: 'Sem Acesso 2')
    user = User.create!(name: 'Auto Edicao', email: 'auto_edicao@example.com', password: 'password123')
    user.profiles << profile
    sign_in user

    get edit_user_path(user)
    assert_response :success
  end
end
