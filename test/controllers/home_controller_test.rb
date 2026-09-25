require 'test_helper'
require_relative '../support/ticket_factory'

class HomeControllerTest < ActionDispatch::IntegrationTest
  include TicketFactory

  def setup
    @requester = create_user('Solicitante')
    @responsible = create_user('Responsavel')
    @admin = create_user('Admin', admin: true)
    responsability = create_responsability(users: [@responsible], hours: 2)
    open = ->(title) { Tickets::Create.call(requester: @requester, attributes: { title: title, description: 'd', ticket_responsability_id: responsability.id }) }
    @mine = open.call('Chamado A')
    @answered = open.call('Chamado B')
    Tickets::AddMessage.call(ticket: @answered, author: @responsible, body: 'Respondido')
    @done = open.call('Chamado C')
    Tickets::AddMessage.call(ticket: @done, author: @responsible, status: 'resolved', body: 'Feito')
  end

  test 'shows the user tickets with counters, open by default' do
    sign_in @requester
    get root_path
    assert_response :success
    assert_select 'td a', text: 'Chamado A'
    assert_select 'td a', text: 'Chamado B'
    assert_select 'td a', text: 'Chamado C', count: 0
    assert_select '[data-counter=waiting_me] .stat-value', text: '1'
    assert_select '[data-counter=waiting_others] .stat-value', text: '1'
    assert_select '[data-counter=resolved_week] .stat-value', text: '1'
  end

  test 'waiting on me and overdue filters' do
    sign_in @responsible
    get root_path, params: { status: 'waiting_me' }
    assert_select 'td a', text: 'Chamado A'
    assert_select 'td a', text: 'Chamado B', count: 0

    travel 3.hours do
      get root_path, params: { status: 'overdue' }
      assert_select 'td a', text: 'Chamado A'
      assert_select 'tr.ticket-row--overdue', minimum: 1
    end
  end

  test 'admin sees everything only when asking for all' do
    sign_in @admin
    get root_path
    assert_select 'td a', text: 'Chamado A', count: 0
    get root_path, params: { scope: 'all', status: 'all' }
    assert_select 'td a', text: 'Chamado C'
  end

  test 'non admins cannot use the all scope' do
    outsider = create_user('Fora')
    sign_in outsider
    get root_path, params: { scope: 'all', status: 'all' }
    assert_select 'td a', count: 0
  end

  test 'each counter links to exactly the list it counts' do
    sign_in @requester
    get root_path
    assert_select "[data-counter=waiting_others][href*='status=waiting_others']"
    assert_select "[data-counter=resolved_week][href*='status=resolved_week']"

    get root_path, params: { status: 'waiting_others' }
    assert_select 'td a', text: 'Chamado A'
    assert_select 'td a', text: 'Chamado B', count: 0

    get root_path, params: { status: 'resolved_week' }
    assert_select 'td a', text: 'Chamado C'
    assert_select 'td a', text: 'Chamado A', count: 0
  end

  test 'sector supervisors can list every ticket of their sectors' do
    supervisor = create_user('Supervisor')
    sign_in supervisor
    get root_path, params: { scope: 'sectors', status: 'all' }
    assert_select 'td a', count: 0

    grant_sectors(supervisor, @mine.ticket_responsability.ticket_sector)
    get root_path, params: { scope: 'sectors', status: 'all' }
    assert_select 'h1', text: /Chamados dos meus setores/
    assert_select 'td a', text: 'Chamado A'
    assert_select 'td a', text: 'Chamado C'
    assert_select 'td', text: @mine.ticket_responsability.ticket_sector.name

    get root_path, params: { scope: 'sectors', status: 'all', ticket_sector_id: create_sector('Outro').id }
    assert_select 'td a', count: 0
  end
end
