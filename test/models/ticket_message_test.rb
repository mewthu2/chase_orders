require 'test_helper'
require_relative '../support/ticket_factory'

class TicketMessageTest < ActiveSupport::TestCase
  include TicketFactory

  def setup
    @user = create_user('Autor')
    @ticket = Ticket.create!(title: 'X', description: 'Y', ticket_responsability: create_responsability(users: [@user]), requester: @user)
  end

  test 'a comment needs a body, an attachment or a status change' do
    message = TicketMessage.new(ticket: @ticket, user: @user, kind: :comment)
    refute message.valid?

    message.status_to = Ticket.statuses['in_progress']
    assert message.valid?
  end

  test 'status names' do
    message = TicketMessage.new(ticket: @ticket, user: @user, body: 'ok', status_from: 0, status_to: 3)
    assert message.status_changed?
    assert_equal 'awaiting_responsible', message.status_from_name
    assert_equal 'resolved', message.status_to_name
  end

  test 'user notification flag' do
    assert @user.ticket_notifications?
    @user.ticket_notifications_enabled = false
    refute @user.ticket_notifications?
    @user.ticket_notifications_enabled = true
    @user.active = false
    refute @user.ticket_notifications?
  end
end
