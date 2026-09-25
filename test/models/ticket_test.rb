require 'test_helper'
require_relative '../support/ticket_factory'

class TicketTest < ActiveSupport::TestCase
  include TicketFactory

  def setup
    @requester = create_user('Solicitante')
    @responsible = create_user('Responsavel')
    @follower = create_user('Acompanhante')
    @admin = create_user('Admin', admin: true)
    @outsider = create_user('Fora')
    @responsability = create_responsability(users: [@responsible], hours: 4)
    @ticket = Ticket.create!(title: 'Impressora', description: 'Não imprime', ticket_responsability: @responsability,
                             requester: @requester, due_at: 4.hours.from_now)
    @ticket.participants.create!(user: @requester, role: :requester)
    @ticket.participants.create!(user: @responsible, role: :responsible)
    @ticket.participants.create!(user: @follower, role: :follower)
  end

  test 'labels and open state' do
    assert_equal 'Aguardando responsável', @ticket.status_label
    assert @ticket.open?
    @ticket.status = :resolved
    refute @ticket.open?
  end

  test 'overdue and due soon' do
    @ticket.due_at = 1.minute.ago
    assert @ticket.overdue?
    refute @ticket.due_soon?

    @ticket.due_at = 90.minutes.from_now
    refute @ticket.overdue?
    assert @ticket.due_soon?

    @ticket.status = :closed
    @ticket.due_at = 1.minute.ago
    refute @ticket.overdue?
  end

  test 'visibility and roles' do
    assert @ticket.visible_to?(@follower)
    assert @ticket.visible_to?(@admin)
    refute @ticket.visible_to?(@outsider)
    assert_equal 'responsible', @ticket.role_of(@responsible)
    assert_nil @ticket.role_of(@admin)
  end

  test 'whose turn it is' do
    assert_equal [@responsible], @ticket.waiting_on_users
    assert_equal 'Responsáveis', @ticket.waiting_on_label
    @ticket.status = :awaiting_requester
    assert_equal [@requester], @ticket.waiting_on_users
    assert @ticket.waiting_on?(@requester)
    @ticket.status = :resolved
    assert_empty @ticket.waiting_on_users
  end

  test 'status options depend on who is acting' do
    assert_equal %w[awaiting_requester in_progress resolved], @ticket.allowed_statuses_for(@responsible)
    assert_equal %w[awaiting_requester in_progress resolved], @ticket.allowed_statuses_for(@follower)
    assert_equal %w[awaiting_requester in_progress closed], @ticket.allowed_statuses_for(@requester)
    assert_equal %w[awaiting_requester in_progress resolved closed], @ticket.allowed_statuses_for(@admin)

    @ticket.status = :resolved
    assert_empty @ticket.allowed_statuses_for(@responsible)
    assert_equal %w[awaiting_responsible awaiting_requester in_progress closed], @ticket.allowed_statuses_for(@requester)

    @ticket.status = :closed
    assert_equal %w[awaiting_responsible awaiting_requester in_progress], @ticket.allowed_statuses_for(@admin)
  end

  test 'cannot be opened for an inactive responsability' do
    @responsability.update!(active: false)
    ticket = Ticket.new(title: 'X', description: 'Y', ticket_responsability: @responsability, requester: @requester)
    refute ticket.valid?
    assert_includes ticket.errors[:ticket_responsability].join, 'inativa'
  end

  test 'scopes' do
    other = Ticket.create!(title: 'Outro', description: 'Z', ticket_responsability: @responsability, requester: @outsider,
                           due_at: 1.hour.ago)
    assert_equal [@ticket], Ticket.involving(@follower).to_a
    assert_includes Ticket.overdue, other
    refute_includes Ticket.overdue, @ticket
    other.update!(overdue_notified_at: Time.current)
    refute_includes Ticket.pending_overdue_notification, other
  end

  test 'rejects forbidden and oversized attachments' do
    ticket = Ticket.new(title: 'X', description: 'Y', ticket_responsability: @responsability, requester: @requester)
    ticket.attachments.attach(io: StringIO.new('MZ'), filename: 'virus.exe', content_type: 'application/x-msdownload')
    refute ticket.valid?
    assert_includes ticket.errors[:attachments].join, 'tipo não permitido'

    big = Ticket.new(title: 'X', description: 'Y', ticket_responsability: @responsability, requester: @requester)
    big.attachments.attach(png_upload)
    big.attachments.first.blob.byte_size = 11.megabytes
    refute big.valid?
    assert_includes big.errors[:attachments].join, 'maior que 10 MB'

    many = Ticket.new(title: 'X', description: 'Y', ticket_responsability: @responsability, requester: @requester)
    11.times { |i| many.attachments.attach(png_upload("p#{i}.png")) }
    refute many.valid?
    assert_includes many.errors[:attachments].join, 'no máximo 10'
  end

  test 'accepts a png print' do
    ticket = Ticket.new(title: 'X', description: 'Y', ticket_responsability: @responsability, requester: @requester)
    ticket.attachments.attach(png_upload)
    assert ticket.valid?, ticket.errors.full_messages.to_sentence
  end

  test 'error messages use Portuguese field names' do
    ticket = Ticket.new(title: 'X', description: 'Y', ticket_responsability: @responsability, requester: @requester)
    ticket.attachments.attach(io: StringIO.new('MZ'), filename: 'virus.exe', content_type: 'application/x-msdownload')
    ticket.valid?
    assert_includes ticket.errors.full_messages.to_sentence, 'Anexos virus.exe'

    responsability = TicketResponsability.new(name: 'Nova', response_time_hours: 1)
    responsability.valid?
    assert_includes responsability.errors.full_messages.to_sentence, 'Responsáveis deve ter'
  end

  test 'people allowed on the sector see its tickets without participating' do
    supervisor = create_user('Supervisor')
    refute @ticket.visible_to?(supervisor)
    refute_includes Ticket.visible_to(supervisor), @ticket

    grant_sectors(supervisor, @responsability.ticket_sector)
    assert Ticket.find(@ticket.id).visible_to?(supervisor)
    assert_includes Ticket.visible_to(supervisor), @ticket
    assert_includes Ticket.visible_to(@follower), @ticket
    assert_includes Ticket.visible_to(@admin), @ticket
  end
end
