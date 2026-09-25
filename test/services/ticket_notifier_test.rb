require 'test_helper'
require_relative '../support/ticket_factory'

class TicketNotifierTest < ActiveSupport::TestCase
  include TicketFactory
  include ActionMailer::TestHelper

  def setup
    ActionMailer::Base.deliveries.clear
    @requester = create_user('Solicitante')
    @responsible = create_user('Responsavel')
    @muted = create_user('Silenciado', ticket_notifications_enabled: false)
    @inactive = create_user('Inativo')
    @ticket = Ticket.create!(title: 'X', description: 'Y', requester: @requester, due_at: 1.hour.from_now,
                             ticket_responsability: create_responsability(users: [@responsible, @muted, @inactive]))
    @ticket.participants.create!(user: @requester, role: :requester)
    [@responsible, @muted, @inactive].each { |user| @ticket.participants.create!(user: user, role: :responsible) }
    @inactive.update!(active: false)
  end

  def delivered_to = ActionMailer::Base.deliveries.flat_map(&:to).sort

  test 'nothing is sent while ticket e-mails are disabled' do
    ENV['TICKET_EMAILS_ENABLED'] = nil
    assert_no_enqueued_emails { TicketNotifier.ticket_opened(@ticket) }
  ensure
    ENV['TICKET_EMAILS_ENABLED'] = 'true'
  end

  test 'opened goes to every participant that accepts notifications' do
    perform_enqueued_jobs { TicketNotifier.ticket_opened(@ticket) }
    assert_equal [@requester.email, @responsible.email].sort, delivered_to
  end

  test 'a message goes to everyone except its author' do
    message = TicketMessage.create!(ticket: @ticket, user: @responsible, body: 'Olhando')
    perform_enqueued_jobs { TicketNotifier.message_created(message) }
    assert_equal [@requester.email], delivered_to
  end

  test 'a muted follower is not e-mailed when added' do
    perform_enqueued_jobs { TicketNotifier.follower_added(@ticket, @muted, added_by: @requester) }
    assert_empty delivered_to
  end

  test 'overdue while waiting on responsibles warns them and the requester' do
    @ticket.update!(due_at: 1.hour.ago)
    perform_enqueued_jobs { TicketNotifier.overdue(@ticket) }
    assert_equal [@requester.email, @responsible.email].sort, delivered_to
  end

  test 'overdue while waiting on the requester warns only the requester' do
    @ticket.update!(status: :awaiting_requester, due_at: 1.hour.ago)
    perform_enqueued_jobs { TicketNotifier.overdue(@ticket) }
    assert_equal [@requester.email], delivered_to
  end
end
