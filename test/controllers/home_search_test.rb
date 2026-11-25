require 'test_helper'

# Tela inicial sem chamados: só a busca "O que você precisa hoje?" sobre as telas liberadas para a pessoa.
class HomeSearchTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(name: 'Admin Home', email: 'admin_home@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @user = User.create!(name: 'Comum Home', email: 'comum_home@example.com', password: 'password123')
  end

  test 'abre com a busca central e sem chamados' do
    sign_in @admin
    get root_path
    assert_response :success
    assert_match 'O que você precisa hoje?', response.body
    assert_select 'input#homeSearch'
    assert_select '.home-tile[href=?]', finance_orders_path
    assert_no_match 'Meus chamados', Nokogiri::HTML(response.body).css('main').text
  end

  test 'menu nao tem mais chamados' do
    sign_in @admin
    get root_path
    ids = Navigation.flatten(Navigation.for(@admin)).map { |e| e[:item][:id] }
    assert_not_includes ids, 'abrir-chamado'
    assert_not_includes ids, 'inicio'
  end

  test 'mostra so as telas liberadas' do
    sign_in @user
    get root_path
    assert_response :success
    assert_select '.home-tile[href=?]', finance_orders_path, count: 0
  end

  test 'painel antigo de chamados continua pelo endereco' do
    sign_in @admin
    get tickets_dashboard_path
    assert_response :success
    assert_match 'Meus chamados', response.body
  end
end
