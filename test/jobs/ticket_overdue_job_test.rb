require 'test_helper'
require_relative '../support/ticket_factory'

class TicketOverdueJobTest < ActiveJob::TestCase
  include TicketFactory
  include ActionMailer::TestHelper

  def setup
    @requester = create_user('Solicitante')
    @responsible = create_user('Responsavel')
    @ticket = Tickets::Create.call(requester: @requester, attributes: {
      title: 'X', description: 'Y', ticket_responsability_id: create_responsability(users: [@responsible], hours: 1).id
    })
    clear_enqueued_jobs
  end

  test 'warns once per overdue period and re-arms after a new interaction' do
    travel 2.hours do
      assert_enqueued_emails(2) { TicketOverdueJob.perform_now }
      assert @ticket.reload.overdue_notified_at
      assert_no_enqueued_emails { TicketOverdueJob.perform_now }

      Tickets::AddMessage.call(ticket: @ticket, author: @responsible, body: 'Respondendo')
      clear_enqueued_jobs
    end

    travel 4.hours do
      assert_enqueued_emails(1) { TicketOverdueJob.perform_now } # só o solicitante, que está com a vez
    end
  end

  test 'ignores tickets that are on time or finished' do
    Tickets::AddMessage.call(ticket: @ticket, author: @responsible, status: 'resolved', body: 'Feito')
    clear_enqueued_jobs
    travel(5.hours) { assert_no_enqueued_emails { TicketOverdueJob.perform_now } }
  end
end
