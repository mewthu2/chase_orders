require 'test_helper'
require_relative '../../support/ticket_factory'

class Tickets::AddMessageTest < ActiveSupport::TestCase
  include TicketFactory
  include ActionMailer::TestHelper

  def setup
    @requester = create_user('Solicitante')
    @responsible = create_user('Responsavel')
    @admin = create_user('Admin', admin: true)
    @outsider = create_user('Fora')
    @responsability = create_responsability(users: [@responsible], hours: 5)
    @ticket = Tickets::Create.call(requester: @requester,
                                   attributes: { title: 'X', description: 'Y', ticket_responsability_id: @responsability.id })
  end

  def add(author, **options) = Tickets::AddMessage.call(ticket: @ticket, author: author, **options)

  test 'a responsible reply hands the turn to the requester and restarts the deadline' do
    @ticket.update!(overdue_notified_at: 1.hour.ago)
    freeze_time do
      assert_enqueued_emails 1 do
        message = add(@responsible, body: 'Vou verificar')
        assert message.persisted?
        refute message.status_changed?
      end
      assert @ticket.reload.awaiting_requester?
      assert_equal 5.hours.from_now, @ticket.due_at
      assert_nil @ticket.overdue_notified_at
    end
  end

  test 'a requester reply hands the turn back to the responsibles' do
    @ticket.update!(status: :awaiting_requester)
    add(@requester, body: 'Segue print')
    assert @ticket.reload.awaiting_responsible?
  end

  test 'resolving requires a solution and stores it' do
    message = add(@responsible, status: 'resolved', body: '')
    refute message.persisted?
    assert_includes message.errors.full_messages.to_sentence, 'solução'
    assert @ticket.reload.awaiting_responsible?

    freeze_time do
      message = add(@responsible, status: 'resolved', body: 'Reiniciei o roteador')
      assert message.persisted?
      assert_equal 'resolved', message.status_to_name
      @ticket.reload
      assert @ticket.resolved?
      assert_equal 'Reiniciei o roteador', @ticket.solution
      assert_equal Time.current, @ticket.resolved_at
      assert_nil @ticket.due_at
    end
  end

  test 'the requester cannot resolve and a responsible cannot close' do
    refute add(@requester, status: 'resolved', body: 'ok').persisted?
    refute add(@responsible, status: 'closed', body: 'ok').persisted?
    assert @ticket.reload.awaiting_responsible?
  end

  test 'reopening restarts the deadline and a comment on a closed ticket keeps it closed' do
    add(@requester, status: 'closed', body: 'Pode fechar')
    assert @ticket.reload.closed?

    add(@requester, body: 'Obrigado!')
    assert @ticket.reload.closed?

    freeze_time do
      add(@requester, status: 'awaiting_responsible', body: 'Voltou a falhar')
      @ticket.reload
      assert @ticket.awaiting_responsible?
      assert_nil @ticket.closed_at
      assert_equal 5.hours.from_now, @ticket.due_at
    end
  end

  test 'an admin outside the ticket can reply and becomes a follower' do
    message = add(@admin, body: 'Acompanhando')
    assert message.persisted?
    assert_equal 'follower', @ticket.reload.role_of(@admin)
  end

  test 'an outsider cannot reply' do
    message = add(@outsider, body: 'oi')
    refute message.persisted?
    assert_equal 0, @ticket.messages.count
  end

  test 'a bad attachment saves nothing and sends nothing' do
    assert_no_enqueued_emails do
      message = add(@responsible, body: 'ver anexo',
                    attachments: [{ io: StringIO.new('MZ'), filename: 'x.exe', content_type: 'application/x-msdownload' }])
      refute message.persisted?
    end
    assert @ticket.reload.awaiting_responsible?
  end

  test 'accepts a print' do
    message = add(@requester, attachments: [png_upload])
    assert message.persisted?, message.errors.full_messages.to_sentence
    assert_equal 1, message.attachments.count
  end

  test 'a sector supervisor can reply and becomes a follower' do
    supervisor = create_user('Supervisor')
    grant_sectors(supervisor, @responsability.ticket_sector)
    message = add(supervisor, body: 'Acompanhando pelo setor')
    assert message.persisted?
    assert_equal 'follower', @ticket.reload.role_of(supervisor)
  end
end
