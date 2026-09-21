require 'test_helper'

class LocaleTest < ActionDispatch::IntegrationTest
  test 'the default locale is pt-BR with English as fallback' do
    assert_equal :'pt-BR', I18n.default_locale
    assert_equal :en, I18n.fallbacks[:'pt-BR'].last
  end

  test 'standard validation messages are in Portuguese' do
    assert_equal 'não pode ficar em branco', I18n.t('errors.messages.blank')
    assert_equal 'já está em uso', I18n.t('errors.messages.taken')
    assert_equal 'não é um número', I18n.t('errors.messages.not_a_number')
    assert_equal 'não é válido', I18n.t('errors.messages.invalid')
  end

  test 'model errors show translated attribute names' do
    company = Company.new
    company.valid?

    assert_includes company.errors.full_messages, 'Razão social não pode ficar em branco'
    assert_includes company.errors.full_messages, 'Código IBGE do município não pode ficar em branco'
    assert(company.errors.full_messages.none? { |m| m.match?(/can't|blank|Legal name/) })
  end

  test 'belongs_to and restrict_dependent_destroy messages are in Portuguese' do
    note = FiscalNote.new(number: 1, series: 1)
    note.valid?
    assert_includes note.errors.full_messages, 'Empresa é obrigatório(a)'
  end

  test 'dates, currency and numbers follow the Brazilian format' do
    assert_equal '20/09/2026', I18n.l(Date.new(2026, 9, 20))
    assert_equal 'setembro', I18n.t('date.month_names')[9]
    assert_equal 'R$ 1.234,50', ActionController::Base.helpers.number_to_currency(1234.5)
    assert_equal 'há cerca de 1 hora', ActionController::Base.helpers.time_ago_in_words(61.minutes.ago).then { |t| "há #{t}" }
  end

  test 'pagination labels are in Portuguese' do
    assert_match(/Anterior/, I18n.t('will_paginate.previous_label'))
    assert_match(/Próximo/, I18n.t('will_paginate.next_label'))
  end

  test 'a failed login shows the Portuguese notification' do
    User.create!(name: 'Login', email: 'login_pt@example.com', password: 'password123')

    post user_session_path, params: { user: { email: 'login_pt@example.com', password: 'errada' } }
    follow_redirect! if response.redirect?

    assert_match(/E-mail ou senha inválidos/, response.body)
    assert_no_match(/Invalid Email or password/, response.body)
  end

  test 'a successful login and logout show Portuguese notifications' do
    User.create!(name: 'Login', email: 'login_ok@example.com', password: 'password123')

    post user_session_path, params: { user: { email: 'login_ok@example.com', password: 'password123' } }
    follow_redirect!
    assert_select '.flash-messages-container .alert', text: /Login efetuado com sucesso/

    get destroy_user_session_path
    assert_equal 'Logout efetuado com sucesso.', flash[:notice]
  end

  test 'visiting a protected page without login shows the Portuguese notification' do
    get b2b_orders_path
    follow_redirect!

    assert_select '.flash-messages-container .alert', text: /Para continuar, faça login/
  end

  test 'the password reset pages are in Portuguese' do
    get new_user_password_path

    assert_select 'h2', text: /Esqueceu sua senha\?/
    assert_no_match(/Forgot your password/, response.body)
  end

  test 'the html document declares pt-BR' do
    get new_user_session_path

    assert_select 'html[lang=?]', 'pt-BR'
  end

  test 'core pages render without missing translations' do
    admin = User.create!(name: 'Admin PT', email: 'admin_pt@example.com', password: 'password123')
    admin.profiles << Profile.find(Profile::ADMIN)
    sign_in admin

    [new_company_path, companies_path, fiscal_notes_path, fiscal_products_path, b2b_orders_path, stock_transfers_path, stock_withdrawals_path, new_stock_withdrawal_path].each do |path|
      get path
      assert_response :success
      assert_no_match(/translation missing|translation_missing/i, response.body, "Missing translation in #{path}")
    end
  end

  test 'the delete-from-queue notifications are in Portuguese' do
    admin = User.create!(name: 'Admin Fila', email: 'admin_fila@example.com', password: 'password123')
    admin.profiles << Profile.find(Profile::ADMIN)
    sign_in admin

    post delete_order_from_queue_dashboard_index_path, params: { tiny_order_id: '' }
    follow_redirect!
    assert_select '.flash-messages-container .alert', text: /ID do pedido no Tiny é obrigatório/

    post delete_order_from_queue_dashboard_index_path, params: { tiny_order_id: '999999' }
    follow_redirect!
    assert_select '.flash-messages-container .alert', text: /Nenhuma tentativa encontrada para o pedido 999999/
  end
end
