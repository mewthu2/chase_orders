require 'test_helper'

class TwoFactorLoginTest < ActionDispatch::IntegrationTest
  setup do
    ActionMailer::Base.deliveries.clear
    @previous = ENV['TWO_FACTOR_LOGIN']
    ENV['TWO_FACTOR_LOGIN'] = 'on'
    @user = User.create!(name: 'Ana Duas Etapas', email: 'ana.2fa@example.com', password: 'senhaforte1')
  end

  teardown { ENV['TWO_FACTOR_LOGIN'] = @previous }

  def login(password: 'senhaforte1', remember: '0')
    post user_session_path, params: { user: { email: @user.email, password: password, remember_me: remember } }
  end

  def sign_out_now
    get destroy_user_session_path
    get root_path
    assert_redirected_to new_user_session_path
  end

  def sent_code
    mail = ActionMailer::Base.deliveries.last
    mail.subject[/\d{6}/]
  end

  test 'right password does not sign in yet: it e-mails a code and asks for it' do
    login

    assert_redirected_to user_two_factor_path
    mail = ActionMailer::Base.deliveries.last
    assert_equal [@user.email], mail.to
    assert_match(/\A\d{6} é o seu código de acesso ao Honey\z/, mail.subject)
    assert_includes mail.html_part.body.decoded, 'Seu código de acesso chegou!'
    assert_includes mail.text_part.body.decoded, sent_code
    assert mail.attachments['chase-logo.png'].inline?

    get root_path
    assert_redirected_to new_user_session_path

    get user_two_factor_path
    assert_response :success
    assert_select 'body.two_factor.show .login-card'
    assert_select 'input#code[autocomplete="one-time-code"][inputmode="numeric"]'
    assert_select '.login-subtitle', text: /an\*+@example\.com/
  end

  test 'the right code signs in and the trusted browser skips the code next time' do
    login
    post user_two_factor_path, params: { code: sent_code, trust_device: '1' }

    assert_redirected_to root_path
    assert_nil @user.reload.login_code_digest
    assert_equal 1, @user.sign_in_count

    sign_out_now
    ActionMailer::Base.deliveries.clear
    login
    assert_redirected_to root_path
    assert_empty ActionMailer::Base.deliveries
  end

  test 'without trusting the browser the next login asks for a new code' do
    login
    post user_two_factor_path, params: { code: sent_code, trust_device: '0' }
    sign_out_now

    login
    assert_redirected_to user_two_factor_path
  end

  test 'changing the password stops trusting the browser' do
    login
    post user_two_factor_path, params: { code: sent_code, trust_device: '1' }
    sign_out_now
    @user.update!(password: 'outrasenha2')

    login(password: 'outrasenha2')
    assert_redirected_to user_two_factor_path
  end

  test 'a wrong code is refused and too many wrong tries burn the code' do
    login
    code = sent_code
    wrong = code == '000000' ? '111111' : '000000'

    post user_two_factor_path, params: { code: wrong }
    assert_response :unprocessable_entity
    assert_select '.login-message-alert', text: /Código incorreto/

    (TwoFactorLogin::MAX_ATTEMPTS - 1).times { post user_two_factor_path, params: { code: wrong } }
    assert_select '.login-message-alert', text: /venceu ou teve tentativas erradas demais/

    post user_two_factor_path, params: { code: code }
    assert_response :unprocessable_entity
    get root_path
    assert_redirected_to new_user_session_path
  end

  test 'an expired code is refused' do
    login
    code = sent_code
    @user.update_columns(login_code_sent_at: 11.minutes.ago)

    post user_two_factor_path, params: { code: code }
    assert_select '.login-message-alert', text: /venceu/
  end

  test 'resend sends a fresh code, but not twice in a row' do
    login
    first = sent_code
    @user.update_columns(login_code_sent_at: 1.minute.ago)

    post resend_user_two_factor_path
    assert_redirected_to user_two_factor_path
    assert_equal 2, ActionMailer::Base.deliveries.size
    refute_equal @user.reload.login_code_digest, nil

    post resend_user_two_factor_path
    follow_redirect!
    assert_select '.login-message-alert', text: /Aguarde/
    assert_equal 2, ActionMailer::Base.deliveries.size
    assert first
  end

  test 'wrong password never sends a code' do
    login(password: 'errada')

    assert_response :unprocessable_entity
    assert_empty ActionMailer::Base.deliveries
  end

  test 'the code page without a pending login goes back to the login' do
    get user_two_factor_path
    assert_redirected_to new_user_session_path
  end

  test 'remember me chosen on the password step survives the code step' do
    login(remember: '1')
    post user_two_factor_path, params: { code: sent_code }

    assert @user.reload.remember_created_at.present?
  end

  test 'with two factor on, resetting the password sends the person back to the login' do
    token = @user.send_reset_password_instructions
    put user_password_path, params: { user: { reset_password_token: token, password: 'senhanova123', password_confirmation: 'senhanova123' } }

    assert_redirected_to new_user_session_path
    get root_path
    assert_redirected_to new_user_session_path
  end

  test 'with two factor off, the password alone signs in' do
    ENV['TWO_FACTOR_LOGIN'] = nil
    login

    assert_redirected_to root_path
    assert_empty ActionMailer::Base.deliveries
  end
end
