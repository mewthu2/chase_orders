require 'test_helper'
require_relative '../support/ticket_factory'

class TicketSectorTest < ActiveSupport::TestCase
  include TicketFactory

  test 'requires a unique name' do
    create_sector('Loja')
    refute TicketSector.new(name: '').valid?
    refute TicketSector.new(name: 'Loja').valid?
  end

  test 'cannot be destroyed while it has responsabilities' do
    sector = create_sector
    create_responsability(users: [create_user('Resp')], ticket_sector: sector)
    refute sector.destroy
    assert TicketSector.exists?(sector.id)
  end

  test 'a responsability needs a sector' do
    responsability = TicketResponsability.new(name: 'Sem setor', response_time_hours: 2, users: [create_user('Resp')])
    refute responsability.valid?
    assert responsability.errors[:ticket_sector].any?
  end

  test 'admins see every sector, others only the ones their profiles grant' do
    loja = create_sector('Loja')
    financeiro = create_sector('Financeiro')
    admin = create_user('Admin', admin: true)
    user = create_user('Comum')

    assert_equal [loja.id, financeiro.id].sort, admin.visible_ticket_sector_ids.sort
    assert_empty user.visible_ticket_sector_ids

    grant_sectors(user, loja)
    assert_equal [loja.id], user.visible_ticket_sector_ids
  end
end
