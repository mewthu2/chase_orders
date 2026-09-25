require 'test_helper'
require_relative '../support/ticket_factory'

class TicketResponsabilitiesControllerTest < ActionDispatch::IntegrationTest
  include TicketFactory

  def setup
    @admin = create_user('Admin', admin: true)
    @user = create_user('Comum')
    @other = create_user('Outro')
  end

  test 'non-admins are redirected' do
    sign_in @user
    get ticket_responsabilities_path
    assert_redirected_to root_path
  end

  test 'admin creates a responsability with responsibles' do
    sign_in @admin
    get new_ticket_responsability_path
    assert_response :success

    post ticket_responsabilities_path, params: { ticket_responsability: {
      name: 'Financeiro', description: 'Pagamentos', response_time_hours: '24', active: '1', user_ids: ['', @user.id, @other.id],
      ticket_sector_id: create_sector('Administrativo').id
    } }
    assert_redirected_to ticket_responsabilities_path
    responsability = TicketResponsability.find_by!(name: 'Financeiro')
    assert_equal [@user, @other].sort_by(&:id), responsability.users.sort_by(&:id)

    get ticket_responsabilities_path
    assert_select 'td', text: 'Financeiro'
    assert_select 'td', text: '1 dia'
  end

  test 'an invalid update keeps the previous responsibles' do
    responsability = create_responsability(users: [@user])
    sign_in @admin

    patch ticket_responsability_path(responsability), params: { ticket_responsability: { name: '', user_ids: [@other.id] } }
    assert_response :unprocessable_entity
    assert_equal [@user], responsability.reload.users
  end

  test 'a responsability with tickets cannot be deleted' do
    responsability = create_responsability(users: [@user])
    Ticket.create!(title: 'X', description: 'Y', ticket_responsability: responsability, requester: @user)
    sign_in @admin

    delete ticket_responsability_path(responsability)
    assert_redirected_to ticket_responsabilities_path
    assert TicketResponsability.exists?(responsability.id)
    assert_match 'Desative', flash[:alert]
  end

  test 'the users menu shows Responsabilidades only for admins' do
    sign_in @admin
    get ticket_responsabilities_path
    assert_select "a[href='#{ticket_responsabilities_path}']", text: /Responsabilidades/

    sign_in @user
    get root_path
    assert_select "a[href='#{ticket_responsabilities_path}']", count: 0
  end
end
