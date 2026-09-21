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

  test 'the login page cancels the logged-in layout offsets that pushed the card off center' do
    css = login_css

    assert_match(/> div \{[^}]*min-height: 100vh !important/m, css)
    assert_match(/\.content-wrapper \{[^}]*margin-top: 0 !important/m, css)
    assert_match(/\.container-xl \{[^}]*max-width: none/m, css)
  end

  test 'the container centers on both axes with a gutter and uses the dynamic viewport height' do
    block = login_css[/\.login-container \{[^}]*\}/m]

    assert_match(/display: flex/, block)
    assert_match(/justify-content: center/, block)
    assert_match(/align-items: center/, block)
    assert_match(/min-height: 100dvh/, block)
    assert_match(/padding: 1rem/, block)
    assert_match(/box-sizing: border-box/, block)
  end

  test 'the card never adds a margin that overflows the viewport on small screens' do
    small_screen = login_css[/@media \(max-width: 576px\) \{.*?\n  \}/m]

    refute_match(/\.login-card \{[^}]*margin:\s*1rem/, small_screen)
  end

  test 'the stylesheet compiles' do
    require 'sassc'
    css = SassC::Engine.new(login_css, syntax: :scss, load_paths: [Rails.root.join('app/assets/stylesheets').to_s]).render

    assert_match(/body\.sessions\.new \.login-container/, css)
  end
end
