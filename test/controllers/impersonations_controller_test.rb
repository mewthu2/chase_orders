require 'test_helper'

class ImpersonationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @super_admin = User.create!(name: 'Daniel', email: 'danielkbr89@gmail.com', password: 'password123')
    @super_admin.profiles << Profile.find(Profile::ADMIN)
    @admin = User.create!(name: 'Outro Admin', email: 'outro_admin@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @user = User.create!(name: 'Vendedora', email: 'vendedora@example.com', password: 'password123')
  end

  test 'super admin logs in as another user by e-mail and comes back' do
    sign_in @super_admin
    get stock_corrections_path
    assert_select '.impersonation-switcher'

    post impersonation_path, params: { email: ' Vendedora@Example.com ' }
    assert_redirected_to root_path
    follow_redirect!
    assert_select '.impersonation-banner', text: /logado como Vendedora/
    assert_select '.impersonation-switcher'
    assert_equal 1, Log.where(user: @super_admin, action_type: 'impersonate', resource_id: @user.id).count

    delete impersonation_path
    assert_redirected_to root_path
    follow_redirect!
    assert_select '.impersonation-banner', count: 0
    assert_equal 1, Log.where(user: @super_admin, action_type: 'stop_impersonating').count
  end

  test 'what the impersonated user sees is their own access' do
    sign_in @super_admin
    post impersonation_path, params: { email: @user.email }
    get users_path
    assert_redirected_to root_path
  end

  test 'a regular admin cannot impersonate and does not see the switcher' do
    sign_in @admin
    get stock_corrections_path
    assert_select '.impersonation-switcher', count: 0

    post impersonation_path, params: { email: @user.email }
    assert_redirected_to root_path
    follow_redirect!
    assert_select '.impersonation-banner', count: 0
  end

  test 'unknown e-mail keeps the super admin logged in as themself' do
    sign_in @super_admin
    post impersonation_path, params: { email: 'ninguem@example.com' }
    follow_redirect!
    assert_select '.impersonation-banner', count: 0
  end

  test 'signing out drops the impersonation so the next login does not inherit it' do
    sign_in @super_admin
    post impersonation_path, params: { email: @user.email }
    get destroy_user_session_path

    post user_session_path, params: { user: { email: @admin.email, password: 'password123' } }
    follow_redirect!
    assert_select '.impersonation-banner', count: 0
    delete impersonation_path
    follow_redirect!
    assert_select '.user-name', text: 'Outro Admin'
  end
end
