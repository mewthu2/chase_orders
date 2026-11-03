require 'test_helper'

class UserStatusTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(name: 'Admin Status', email: 'admin_status@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @person = User.create!(name: 'Pessoa Comum', email: 'pessoa_status@example.com', password: 'password123')
  end

  test 'an admin deactivates and reactivates someone from the list' do
    sign_in @admin
    get users_path
    assert_select 'form[action=?][data-hc-confirm]', toggle_status_user_path(@person)

    patch toggle_status_user_path(@person)
    assert_redirected_to users_path
    refute @person.reload.active

    patch toggle_status_user_path(@person)
    assert @person.reload.active
  end

  test 'nobody toggles their own account from the list' do
    sign_in @admin
    patch toggle_status_user_path(@admin)
    assert @admin.reload.active
  end

  test 'a deactivated person cannot sign in' do
    @person.update!(active: false)
    post user_session_path, params: { user: { email: @person.email, password: 'password123' } }
    get root_path
    assert_redirected_to new_user_session_path
  end

  test 'the reset link is e-mailed to the person' do
    sign_in @admin
    assert_emails 1 do
      post send_password_reset_user_path(@person)
    end
    assert_redirected_to users_path
  end

  test 'sign in records the last access shown in the list' do
    post user_session_path, params: { user: { email: @admin.email, password: 'password123' } }
    assert @admin.reload.last_sign_in_at.present?
  end
end
