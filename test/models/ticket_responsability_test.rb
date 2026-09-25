require 'test_helper'
require_relative '../support/ticket_factory'

class TicketResponsabilityTest < ActiveSupport::TestCase
  include TicketFactory

  test 'requires name, positive hours and at least one active responsible' do
    inactive = create_user('Inativo', active: false)
    responsability = TicketResponsability.new(name: '', response_time_hours: 0, users: [inactive])

    refute responsability.valid?
    assert responsability.errors[:name].any?
    assert responsability.errors[:response_time_hours].any?
    assert_includes responsability.errors[:users].join, 'pelo menos um responsável ativo'
  end

  test 'formats the response time' do
    user = create_user('Resp')
    assert_equal '4h', create_responsability(users: [user], hours: 4).response_time_label
    assert_equal '1 dia', create_responsability(users: [user], hours: 24).response_time_label
    assert_equal '3 dias', create_responsability(users: [user], hours: 72).response_time_label
    assert_equal '30h', create_responsability(users: [user], hours: 30).response_time_label
  end

  test 'cannot be destroyed once it has tickets, and keeps its responsibles' do
    user = create_user('Resp')
    responsability = create_responsability(users: [user])
    Ticket.create!(title: 'X', description: 'Y', ticket_responsability: responsability, requester: user)

    refute responsability.destroy
    assert_equal [user], responsability.reload.users
  end
end
