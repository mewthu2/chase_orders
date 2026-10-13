require 'test_helper'

class PasswordRecoveryTest < ActionDispatch::IntegrationTest
  setup do
    ActionMailer::Base.deliveries.clear
    @user = User.create!(name: 'Maria Recupera', email: 'maria.recupera@example.com', password: 'senhaantiga1')
  end

  test 'the forgot password page uses the login card with a way back to the login' do
    get new_user_password_path

    assert_response :success
    assert_select 'body.passwords.new .login-container .login-card'
    assert_select 'input#user_email[type="email"][required]'
    assert_select 'a[href=?]', new_user_session_path, text: /Voltar para o login/
  end

  test 'requesting a reset sends the styled e-mail with the reset link' do
    post user_password_path, params: { user: { email: @user.email } }

    assert_redirected_to new_user_session_path
    follow_redirect!
    assert_select '.login-card .login-message-notice', text: /receberá um link para redefinir sua senha/

    mail = ActionMailer::Base.deliveries.last
    assert_equal [@user.email], mail.to
    assert_equal [ENV.fetch('MAILER_FROM', 'chamados@chaseorders.com')], mail.from
    assert_equal 'Instruções para redefinir sua senha', mail.subject
    assert mail.attachments['chase-logo.png'].inline?
    html = mail.html_part.body.decoded
    assert_includes html, 'Maria Recupera'
    assert_match %r{/user/password/edit\?reset_password_token=}, html
    assert_match %r{/user/password/edit\?reset_password_token=}, mail.text_part.body.decoded
  end

  test 'an unknown e-mail gets the same answer and no e-mail, so accounts are not revealed' do
    post user_password_path, params: { user: { email: 'ninguem@example.com' } }

    assert_redirected_to new_user_session_path
    follow_redirect!
    assert_select '.login-message-notice', text: /receberá um link para redefinir sua senha/
    assert_empty ActionMailer::Base.deliveries
  end

  test 'the reset link lets the user set a new password, signs in and warns by e-mail' do
    token = @user.send_reset_password_instructions
    ActionMailer::Base.deliveries.clear

    get edit_user_password_path(reset_password_token: token)
    assert_response :success
    assert_select 'body.passwords.edit .login-card'
    assert_select 'input#user_password[autocomplete="new-password"][minlength="6"]'
    assert_select 'input#user_password_confirmation[autocomplete="new-password"]'
    assert_select '.password-rules li', 2

    put user_password_path, params: { user: { reset_password_token: token, password: 'senhanova123', password_confirmation: 'senhanova123' } }

    assert_redirected_to root_path
    assert @user.reload.valid_password?('senhanova123')
    mail = ActionMailer::Base.deliveries.last
    assert_equal 'Senha alterada', mail.subject
    assert_includes mail.html_part.body.decoded, 'Sua senha foi alterada'
  end

  test 'mismatched confirmation shows the error inside the card and keeps the old password' do
    token = @user.send_reset_password_instructions

    put user_password_path, params: { user: { reset_password_token: token, password: 'senhanova123', password_confirmation: 'outra' } }

    assert_response :unprocessable_entity
    assert_select '.login-card .login-message-alert'
    assert @user.reload.valid_password?('senhaantiga1')
  end

  test 'a wrong password shows the error message on the login card' do
    post user_session_path, params: { user: { email: @user.email, password: 'errada' } }
    follow_redirect! if response.redirect?

    assert_select '.login-card .login-message-alert', text: /inválid/
  end
end
