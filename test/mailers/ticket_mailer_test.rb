require 'test_helper'
require_relative '../support/ticket_factory'

class TicketMailerTest < ActionMailer::TestCase
  include TicketFactory

  def setup
    @requester = create_user('Ana Solicitante')
    @responsible = create_user('Bruno Responsavel')
    @responsability = create_responsability(users: [@responsible], hours: 8, name: 'Suporte TI')
    @ticket = Ticket.create!(title: 'Impressora parada', description: 'A impressora do caixa não liga',
                             ticket_responsability: @responsability, requester: @requester, due_at: 8.hours.from_now)
    @ticket.participants.create!(user: @requester, role: :requester)
    @ticket.participants.create!(user: @responsible, role: :responsible)
  end

  test 'opened e-mail tells who was notified and the deadline' do
    mail = TicketMailer.with(ticket: @ticket, recipient: @responsible).opened

    assert_equal [@responsible.email], mail.to
    assert_equal "[Chamado ##{@ticket.id}] Novo: Impressora parada", mail.subject
    html = mail.html_part.body.to_s
    assert_includes html, 'Suporte TI'
    assert_includes html, 'Bruno Responsavel'
    assert_includes html, 'A impressora do caixa não liga'
    assert_includes html, @ticket.due_at.strftime('%d/%m/%Y')
    assert_includes html, "/tickets/#{@ticket.id}"
    assert_includes mail.text_part.body.to_s, 'Impressora parada'
    assert mail.attachments['chase-logo.png'].inline?
  end

  test 'new_message e-mail shows the message and the solution when resolved' do
    message = TicketMessage.create!(ticket: @ticket, user: @responsible, body: 'Troquei o cabo de força',
                                    status_from: 0, status_to: Ticket.statuses['resolved'])
    mail = TicketMailer.with(ticket: @ticket, recipient: @requester, message: message).new_message

    assert_equal "[Chamado ##{@ticket.id}] Resolvido: Impressora parada", mail.subject
    assert_includes mail.html_part.body.to_s, 'Troquei o cabo de força'
    assert_includes mail.html_part.body.to_s, 'Solução'
  end

  test 'plain new_message subject names the author' do
    message = TicketMessage.create!(ticket: @ticket, user: @requester, body: 'Alguma novidade?')
    mail = TicketMailer.with(ticket: @ticket, recipient: @responsible, message: message).new_message

    assert_equal "[Chamado ##{@ticket.id}] Nova interação de Ana Solicitante", mail.subject
  end

  test 'follower_added and overdue subjects' do
    follower = create_user('Carla Acompanha')
    @ticket.participants.create!(user: follower, role: :follower)

    added = TicketMailer.with(ticket: @ticket, recipient: follower, added_by: @requester).follower_added
    assert_equal "[Chamado ##{@ticket.id}] Você foi chamado para acompanhar: Impressora parada", added.subject
    assert_includes added.html_part.body.to_s, 'Ana Solicitante'

    @ticket.update!(due_at: 3.hours.ago)
    overdue = TicketMailer.with(ticket: @ticket, recipient: @responsible).overdue
    assert_equal "[Chamado ##{@ticket.id}] ⚠ Prazo vencido: Impressora parada", overdue.subject
    assert_includes overdue.html_part.body.to_s, 'vencido há 3h'
  end

  test 'the e-mail has a hero, a status progress bar and a lively footer' do
    mail = TicketMailer.with(ticket: @ticket, recipient: @responsible).opened
    html = mail.html_part.body.to_s

    assert_includes html, '🎫'
    assert_includes html, 'class="progress-step progress-step--current"'
    assert_includes html, '@keyframes'
    assert_includes html, 'prefers-reduced-motion'
    assert_includes html, 'Quem está neste chamado'
    assert_includes html, 'Feito com'
    assert_includes html, 'Meus chamados'
    assert_includes html, 'http://example.com/'
    assert_includes html, 'Abrir novo chamado'
    assert_includes html, 'Dica'
  end

  test 'hero changes with the event' do
    resolved = TicketMessage.create!(ticket: @ticket, user: @responsible, body: 'Feito', status_from: 0, status_to: 3)
    assert_includes TicketMailer.with(ticket: @ticket, recipient: @requester, message: resolved).new_message.html_part.body.to_s, '✅'

    @ticket.update!(due_at: 1.hour.ago)
    assert_includes TicketMailer.with(ticket: @ticket, recipient: @responsible).overdue.html_part.body.to_s, '⏰'
  end
end
