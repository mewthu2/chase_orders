require 'test_helper'

class LoginLayoutTest < ActionDispatch::IntegrationTest
  CSS_PATH = Rails.root.join('app/assets/stylesheets/admin/pages/_devise.scss')

  def login_css
    CSS_PATH.read
  end

  test 'the login page renders the card scoped by the sessions/new body class' do
    get new_user_session_path

    assert_response :success
    assert_select 'body.sessions.new'
    assert_select '.login-container .login-card'
  end

  test 'login fields have associated labels and support password managers' do
    get new_user_session_path

    assert_select 'label[for="user_email"]', text: 'E-mail'
    assert_select 'input#user_email[type="email"][required][autocomplete="username"]'
    assert_select 'label[for="user_password"]', text: 'Senha'
    assert_select 'input#user_password[type="password"][required][autocomplete="current-password"]'
    assert_select 'button[type="button"][aria-controls="user_password"][aria-pressed="false"]'
    assert_select 'a[href=?]', new_user_password_path, text: 'Esqueci minha senha'
  end

  test 'the authentication message appears once next to the login form' do
    get root_path
    assert_redirected_to new_user_session_path
    follow_redirect!

    assert_select '.login-card .login-message-alert[role="alert"]', count: 1
    assert_select '.flash-messages-container .alert', count: 0
  end

  test 'the login shows the brand panel next to the card' do
    get new_user_session_path

    assert_select '.login-view .login-brand .brand-points li', count: 3
    assert_select '.login-view .login-side .login-container .login-card'
    assert_select '.login-card button[type="submit"].btn-login', text: /Entrar/
    assert_select '#appView', count: 0
  end

  test 'the login look lives in honey.css and the brand panel hides on small screens' do
    css = Rails.root.join('app/assets/stylesheets/honey.css').read

    assert_match(/\.login-view \.login-card \{/, css)
    assert_match(/@media \(max-width: 1080px\) \{[^@]*\.login-view \.login-brand \{ display: none; \}/m, css)
  end

  test 'the stylesheets compile' do
    require 'sassc'
    css = SassC::Engine.new(login_css, syntax: :scss, load_paths: [Rails.root.join('app/assets/stylesheets').to_s]).render
    assert_match(/\.login-view \.password-rules/, css)

    honey = Rails.application.assets['honey.css'].to_s
    assert_match(/\.login-view \.login-card/, honey)
  end
end
