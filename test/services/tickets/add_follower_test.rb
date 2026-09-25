require 'test_helper'
require_relative '../../support/ticket_factory'

class Tickets::AddFollowerTest < ActiveSupport::TestCase
  include TicketFactory
  include ActionMailer::TestHelper

  def setup
    @requester = create_user('Solicitante')
    @responsible = create_user('Responsavel')
    @guest = create_user('Convidado')
    @ticket = Tickets::Create.call(requester: @requester, attributes: {
      title: 'X', description: 'Y', ticket_responsability_id: create_responsability(users: [@responsible]).id
    })
  end

  test 'adds the follower, logs an event and e-mails only the follower' do
    result = nil
    assert_enqueued_emails 1 do
      result = Tickets::AddFollower.call(ticket: @ticket, user: @guest, added_by: @requester)
    end
    assert result.success?
    assert_equal 'follower', @ticket.reload.role_of(@guest)
    assert_equal "Solicitante chamou Convidado para acompanhar o chamado", @ticket.messages.event.last.body
  end

  test 'refuses duplicates, inactive users and outsiders' do
    assert_equal 'Responsavel já participa deste chamado',
                 Tickets::AddFollower.call(ticket: @ticket, user: @responsible, added_by: @requester).error
    @guest.update!(active: false)
    refute Tickets::AddFollower.call(ticket: @ticket, user: @guest, added_by: @requester).success?
    outsider = create_user('Fora')
    refute Tickets::AddFollower.call(ticket: @ticket, user: create_user('Outro'), added_by: outsider).success?
  end
end
