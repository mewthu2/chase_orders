require 'test_helper'
require_relative '../support/ticket_factory'

class TicketSectorsControllerTest < ActionDispatch::IntegrationTest
  include TicketFactory

  def setup
    @admin = create_user('Admin', admin: true)
  end

  test 'non-admins are redirected' do
    sign_in create_user('Comum')
    get ticket_sectors_path
    assert_redirected_to root_path
  end

  test 'admin creates, renames and lists sectors' do
    sign_in @admin
    get new_ticket_sector_path
    assert_response :success

    post ticket_sectors_path, params: { ticket_sector: { name: 'Lojas', description: 'Operação das lojas', active: '1' } }
    assert_redirected_to ticket_sectors_path
    sector = TicketSector.find_by!(name: 'Lojas')

    patch ticket_sector_path(sector), params: { ticket_sector: { name: 'Lojas físicas' } }
    assert_equal 'Lojas físicas', sector.reload.name

    get ticket_sectors_path
    assert_select 'td', text: 'Lojas físicas'
  end

  test 'a sector with responsabilities cannot be deleted' do
    sector = create_sector
    create_responsability(users: [create_user('Resp')], ticket_sector: sector)
    sign_in @admin
    delete ticket_sector_path(sector)
    assert TicketSector.exists?(sector.id)
    assert_match 'Desative', flash[:alert]
  end

  test 'the profile screen lets the admin pick which sectors a profile sees' do
    loja = create_sector('Lojas')
    financeiro = create_sector('Financeiro')
    profile = Profile.create!(name: 'Gerentes de loja')
    sign_in @admin

    get edit_profile_path(profile)
    assert_select "input[type=checkbox][name='profile[ticket_sector_ids][]'][value='#{loja.id}']"

    patch profile_path(profile), params: { profile: { name: 'Gerentes de loja', ticket_sector_ids: ['', loja.id] } }
    assert_equal [loja], profile.reload.ticket_sectors

    patch profile_path(profile), params: { profile: { name: 'Gerentes de loja', ticket_sector_ids: [''] } }
    assert_empty profile.reload.ticket_sectors
    refute_nil financeiro
  end

  test 'responsabilities show and require their sector' do
    sector = create_sector('Lojas')
    responsible = create_user('Resp')
    sign_in @admin

    post ticket_responsabilities_path, params: { ticket_responsability: { name: 'Sem setor', response_time_hours: '4', user_ids: [responsible.id] } }
    assert_response :unprocessable_entity

    post ticket_responsabilities_path, params: { ticket_responsability: {
      name: 'Manutenção', response_time_hours: '4', ticket_sector_id: sector.id, user_ids: [responsible.id]
    } }
    assert_redirected_to ticket_responsabilities_path
    get ticket_responsabilities_path
    assert_select 'td', text: 'Lojas'
  end
end
