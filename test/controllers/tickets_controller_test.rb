require 'test_helper'
require_relative '../support/ticket_factory'

class TicketsControllerTest < ActionDispatch::IntegrationTest
  include TicketFactory
  include ActionMailer::TestHelper

  def setup
    @requester = create_user('Solicitante')
    @responsible = create_user('Responsavel')
    @admin = create_user('Admin', admin: true)
    @outsider = create_user('Fora')
    @guest = create_user('Convidado')
    @responsability = create_responsability(users: [@responsible], name: 'Suporte TI')
  end

  def open_ticket
    Tickets::Create.call(requester: @requester, attributes: { title: 'Sem rede', description: 'Caiu', ticket_responsability_id: @responsability.id })
  end

  test 'any user opens a ticket with a print and followers' do
    grant_sectors(@requester, @responsability.ticket_sector)
    sign_in @requester
    get new_ticket_path
    assert_response :success
    assert_select 'option', text: 'Suporte TI'

    assert_enqueued_emails 3 do
      post tickets_path, params: { ticket: {
        ticket_responsability_id: @responsability.id, title: 'Sem rede', description: 'Caiu tudo',
        attachments: [fixture_file_upload(Rails.root.join('app/assets/images/admin/chase-logo.png'), 'image/png')],
        follower_ids: ['', @guest.id]
      } }
    end
    ticket = Ticket.last
    assert_redirected_to ticket_path(ticket)
    assert_equal 1, ticket.attachments.count
  end

  test 'invalid ticket re-renders the form' do
    grant_sectors(@requester, @responsability.ticket_sector)
    sign_in @requester
    post tickets_path, params: { ticket: { ticket_responsability_id: @responsability.id, title: '', description: '' } }
    assert_response :unprocessable_entity
    assert_select '.form-error-box'
  end

  test 'only participants and admins see the ticket' do
    ticket = open_ticket
    sign_in @outsider
    get ticket_path(ticket)
    assert_redirected_to root_path

    sign_in @admin
    get ticket_path(ticket)
    assert_response :success
    assert_select 'h1', text: /Sem rede/
  end

  test 'posting an interaction changes the status and shows it in the timeline' do
    ticket = open_ticket
    sign_in @responsible
    post ticket_ticket_messages_path(ticket), params: { ticket_message: { body: 'Resolvido trocando o cabo', status: 'resolved' } }
    message = ticket.messages.last
    assert_redirected_to ticket_path(ticket, anchor: "message-#{message.id}")
    assert ticket.reload.resolved?

    follow_redirect!
    assert_select '.ticket-solution', text: /Resolvido trocando o cabo/
  end

  test 'a rejected interaction keeps the typed text' do
    ticket = open_ticket
    sign_in @responsible
    post ticket_ticket_messages_path(ticket), params: { ticket_message: { body: '', status: 'resolved' } }
    assert_response :unprocessable_entity
    assert_select '.form-error-box', text: /solução/
  end

  test 'a bad file is rejected on the page' do
    ticket = open_ticket
    sign_in @requester
    post ticket_ticket_messages_path(ticket), params: { ticket_message: {
      body: 'veja', attachments: [fixture_file_upload(Rails.root.join('Gemfile'), 'application/x-msdownload')]
    } }
    assert_response :unprocessable_entity
    assert_equal 0, ticket.messages.comment.count
  end

  test 'an outsider cannot post and an admin can' do
    ticket = open_ticket
    sign_in @outsider
    post ticket_ticket_messages_path(ticket), params: { ticket_message: { body: 'oi' } }
    assert_redirected_to root_path

    sign_in @admin
    post ticket_ticket_messages_path(ticket), params: { ticket_message: { body: 'Estou acompanhando' } }
    assert_equal 'follower', ticket.reload.role_of(@admin)
  end

  test 'a participant calls someone to follow' do
    ticket = open_ticket
    sign_in @requester
    post ticket_ticket_participants_path(ticket), params: { user_id: @guest.id }
    assert_redirected_to ticket_path(ticket)
    assert_equal 'follower', ticket.reload.role_of(@guest)
  end

  test 'the form hides areas without an active responsible' do
    lonely = create_user('Sozinho')
    create_responsability(users: [lonely], name: 'Area Vazia')
    lonely.update!(active: false)
    grant_sectors(@requester, @responsability.ticket_sector, TicketResponsability.find_by!(name: 'Area Vazia').ticket_sector)
    sign_in @requester
    get new_ticket_path
    assert_select 'option', text: 'Suporte TI'
    assert_select 'option', text: 'Area Vazia', count: 0
  end

  test 'only admins can delete a ticket, and everything goes with it' do
    ticket = open_ticket
    Tickets::AddMessage.call(ticket: ticket, author: @responsible, body: 'Olhando', attachments: [png_upload])

    [@requester, @responsible].each do |user|
      sign_in user
      get ticket_path(ticket)
      assert_select "form[action='#{ticket_path(ticket)}'] button", count: 0
      delete ticket_path(ticket)
      assert_redirected_to root_path
      assert Ticket.exists?(ticket.id)
    end

    sign_in @admin
    get ticket_path(ticket)
    assert_select "form[action='#{ticket_path(ticket)}'] button[title='Excluir chamado']"
    get root_path(scope: 'all', status: 'all')
    assert_select "form[action='#{ticket_path(ticket)}'] button[title='Excluir chamado']"

    assert_no_enqueued_emails do
      delete ticket_path(ticket)
    end
    assert_redirected_to root_path
    assert_match 'excluído', flash[:notice]
    refute Ticket.exists?(ticket.id)
    assert_equal 0, TicketMessage.where(ticket_id: ticket.id).count
    assert_equal 0, TicketParticipant.where(ticket_id: ticket.id).count
  end

  test 'the form only offers responsabilities of the sectors the user may see, grouped by sector' do
    other = create_responsability(users: [@responsible], name: 'Financeiro Pagamentos', ticket_sector: create_sector('Financeiro'))
    grant_sectors(@requester, @responsability.ticket_sector)
    sign_in @requester

    get new_ticket_path
    assert_select "optgroup[label='#{@responsability.ticket_sector.name}'] option", text: 'Suporte TI'
    assert_select 'option', text: 'Financeiro Pagamentos', count: 0

    assert_no_difference 'Ticket.count' do
      post tickets_path, params: { ticket: { ticket_responsability_id: other.id, title: 'Burlando', description: 'x' } }
    end
    assert_response :unprocessable_entity
  end

  test 'a user without sectors cannot open tickets' do
    sign_in @outsider
    get new_ticket_path
    assert_select 'option', text: 'Suporte TI', count: 0
    assert_select '.ticket-empty', text: /nenhum setor/
  end

  test 'a sector supervisor sees and answers tickets of the sector' do
    ticket = open_ticket
    supervisor = create_user('Supervisor')
    grant_sectors(supervisor, @responsability.ticket_sector)
    sign_in supervisor

    get ticket_path(ticket)
    assert_response :success
    assert_select 'dd', text: @responsability.ticket_sector.name

    post ticket_ticket_messages_path(ticket), params: { ticket_message: { body: 'Estou de olho' } }
    assert_equal 'follower', ticket.reload.role_of(supervisor)
  end
end
