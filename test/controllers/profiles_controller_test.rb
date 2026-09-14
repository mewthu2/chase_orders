require 'test_helper'

class ProfilesControllerTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(name: 'Admin', email: 'admin_profiles@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
  end

  test 'non-admin is redirected away from the index' do
    profile = Profile.create!(name: 'Perfil Comum')
    user = User.create!(name: 'Comum', email: 'comum@example.com', password: 'password123')
    user.profiles << profile
    sign_in user

    get profiles_path
    assert_redirected_to root_path
  end

  test 'admin can list, create, update and see the screen checkboxes' do
    sign_in @admin

    get profiles_path
    assert_response :success

    get new_profile_path
    assert_response :success

    assert_difference 'Profile.count', 1 do
      post profiles_path, params: { profile: { name: 'Financeiro', description: 'Time financeiro', active: true, screen_keys: ['orders', 'customers'] } }
    end
    profile = Profile.find_by(name: 'Financeiro')
    assert_redirected_to profiles_path
    assert_equal %w[customers orders], profile.screen_keys.sort

    patch profile_path(profile), params: { profile: { screen_keys: ['orders'] } }
    assert_equal ['orders'], profile.reload.screen_keys
  end

  test 'destroy is blocked when the profile still has users' do
    sign_in @admin

    profile_with_user = Profile.create!(name: 'Com Usuario')
    other_user = User.create!(name: 'Outro', email: 'outro@example.com', password: 'password123')
    other_user.profiles << profile_with_user

    assert_no_difference 'Profile.count' do
      delete profile_path(profile_with_user)
    end
    assert_redirected_to profiles_path
  end

  test 'destroy works when the profile has no users' do
    sign_in @admin
    empty_profile = Profile.create!(name: 'Vazio')

    assert_difference 'Profile.count', -1 do
      delete profile_path(empty_profile)
    end
  end

  test 'the sidebar shows the profiles link only to admins' do
    sign_in @admin
    get root_path
    assert_select "a[href='#{profiles_path}']", text: /Perfis e Permissões/

    sign_out @admin
    profile = Profile.create!(name: 'Perfil Comum 2')
    user = User.create!(name: 'Comum 2', email: 'comum2@example.com', password: 'password123')
    user.profiles << profile
    sign_in user

    get root_path
    assert_select "a[href='#{profiles_path}']", count: 0
  end
end
