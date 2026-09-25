require 'test_helper'
require_relative '../../support/ticket_factory'

class Tickets::CreateTest < ActiveSupport::TestCase
  include TicketFactory
  include ActionMailer::TestHelper

  def setup
    @requester = create_user('Solicitante')
    @responsible = create_user('Responsavel')
    @follower = create_user('Acompanhante')
    @responsability = create_responsability(users: [@responsible], hours: 6)
  end

  def attributes = { title: 'Sem internet', description: 'Loja sem rede', ticket_responsability_id: @responsability.id }

  test 'opens the ticket with snapshot participants, deadline and e-mails' do
    ticket = nil
    freeze_time do
      assert_enqueued_emails 3 do
        ticket = Tickets::Create.call(requester: @requester, attributes: attributes, follower_ids: ['', @follower.id.to_s])
      end
      assert ticket.persisted?
      assert ticket.awaiting_responsible?
      assert_equal 6.hours.from_now, ticket.due_at
      assert_equal Time.current, ticket.last_activity_at
    end
    assert_equal({ @requester.id => 'requester', @responsible.id => 'responsible', @follower.id => 'follower' },
                 ticket.participants.to_h { |participant| [participant.user_id, participant.role] })

    @responsability.update!(users: [@follower])
    assert_equal [@responsible], ticket.reload.responsibles
  end

  test 'requester who is also a responsible appears once' do
    @responsability.update!(users: [@responsible, @requester])
    ticket = Tickets::Create.call(requester: @requester, attributes: attributes, follower_ids: [@requester.id])
    assert_equal 2, ticket.participants.count
    assert_equal 'requester', ticket.role_of(@requester)
  end

  test 'invalid ticket is not saved and sends nothing' do
    assert_no_enqueued_emails do
      ticket = Tickets::Create.call(requester: @requester, attributes: attributes.merge(title: ''))
      refute ticket.persisted?
      assert ticket.errors[:title].any?
    end
  end

  test 'refuses an area with no active responsible besides the requester' do
    @responsability.update!(users: [@responsible, @requester])
    @responsible.update!(active: false)
    assert_no_enqueued_emails do
      ticket = Tickets::Create.call(requester: @requester, attributes: attributes)
      refute ticket.persisted?
      assert_includes ticket.errors.full_messages.to_sentence, 'responsável ativo'
    end
  end
end
