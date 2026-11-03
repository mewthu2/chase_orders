require 'test_helper'

# Menu lateral por área do negócio (Navigation + layouts/partials/_sidebar).
class SidebarTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(name: 'Admin Menu', email: 'admin_menu@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
  end

  def user_with(keys)
    profile = Profile.create!(name: "Menu #{SecureRandom.hex(3)}")
    profile.update!(screen_keys: keys)
    User.create!(name: 'Menu', email: "menu_#{SecureRandom.hex(3)}@example.com", password: 'password123').tap { |u| u.profiles << profile }
  end

  test 'admins see every business area, in order' do
    sign_in @admin
    get root_path

    assert_select '.sb-section .sb-area-name', count: Screen::AREAS.size
    assert_select '.sb-section:first-child .sb-area-name', text: 'Geral'
    assert_select ".sb-section[data-area='adm'] a[href='#{companies_path}']", text: /Empresas/
    assert_select ".sb-section[data-area='adm'] a[href='#{operation_natures_path}']", text: /Naturezas de Operação/
    assert_select ".sb-section[data-area='adm'] a[href='#{fiscal_notes_path}']", text: /Notas Fiscais/
    assert_select ".sb-section[data-area='adm'] a[href='#{profiles_path}']", text: /Perfis e Permissões/
  end

  test 'a user only sees the areas and screens their profile opens' do
    sign_in user_with(['stock_corrections'])
    get stock_corrections_path

    assert_select ".sb-section[data-area='loja'] a[href='#{stock_corrections_path}']"
    assert_select "a[href='#{stock_withdrawals_path}']", count: 0
    assert_select "a[href='#{companies_path}']", count: 0
    assert_select ".sb-section[data-area='adm']", count: 0
    assert_select ".sb-section[data-area='geral']", count: 1
  end

  test 'the current screen is highlighted and its area shows in the top trail' do
    sign_in user_with(['transfer_locations'])
    get transfer_locations_path

    assert_response :success
    assert_select ".sb-link.is-active[href='#{transfer_locations_path}']"
    assert_select '.sb-section.has-active[data-area="logistica"]'
    assert_select '.crumbs .area-crumb', text: /Logística/
    assert_select '.crumbs .current', text: 'Locais de Transferência'
  end

  test 'Log02 keeps its approval and creation steps numbered' do
    sign_in @admin
    get root_path

    assert_select ".sb-group[data-group='log02'] .sb-steps .sb-step", text: '1'
    assert_select ".sb-group[data-group='log02'] .sb-aka", text: 'Correios B2B'
  end

  test 'every user gets their tickets and a way to open one' do
    user = User.create!(name: 'Comum Menu', email: 'comum_menu@example.com', password: 'password123')
    sign_in user
    get root_path

    assert_select ".sb-group[data-group='chamados']" do
      assert_select "a[href='#{root_path}']", text: /Meus chamados/
      assert_select "a[href='#{new_ticket_path}']", text: /Abrir chamado/
      assert_select "a[href='#{root_path(scope: 'all', status: 'all')}']", count: 0
    end
    assert_select "a[href='#{ticket_responsabilities_path}']", count: 0
  end

  test 'admins manage sectors and responsabilities under Acessos e equipe' do
    sign_in @admin
    get root_path

    assert_select ".sb-group[data-group='acessos'] a[href='#{ticket_sectors_path}']", text: /Setores/
    assert_select ".sb-group[data-group='acessos'] a[href='#{ticket_responsabilities_path}']", text: /Responsabilidades/
    assert_select ".sb-group[data-group='chamados'] a[href='#{root_path(scope: 'all', status: 'all')}']", text: /Todos os chamados/
  end

  test 'sector supervisors see the tickets of their sectors' do
    supervisor = User.create!(name: 'Supervisor Menu', email: 'supervisor_menu@example.com', password: 'password123')
    supervisor.profiles << Profile.create!(name: 'Supervisores', ticket_sectors: [TicketSector.create!(name: 'Lojas Menu')])
    sign_in supervisor
    get root_path

    assert_select ".sb-group[data-group='chamados'] a[href='#{root_path(scope: 'sectors', status: 'all')}']", text: /Chamados dos meus setores/
    assert_select "a[href='#{ticket_sectors_path}']", count: 0
  end

  test 'the help drawer, map and quick search data are on the page' do
    sign_in user_with(['carriers'])
    get carriers_path

    assert_select 'template#helpTemplate'
    assert_select 'template#mapTemplate'
    data = JSON.parse(css_select('#honeyData').first.text)
    assert_includes data['search']['screens'].map { |s| s['id'] }, 'adm-transportadoras'
    refute_includes data['search']['screens'].map { |s| s['id'] }, 'adm-empresas'
  end
end
