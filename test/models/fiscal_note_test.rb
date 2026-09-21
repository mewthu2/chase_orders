require 'test_helper'

class FiscalNoteTest < ActiveSupport::TestCase
  def setup
    @company = Company.create!(
      legal_name: 'Empresa Nota', cnpj: '11222333000181', tax_regime: 1, street: 'Rua A', number: '1',
      neighbourhood: 'Centro', city: 'BH', city_ibge_code: '3106200', state: 'MG', zip: '30000000'
    )
  end

  def build_note(overrides = {})
    FiscalNote.new({ company: @company, number: 1, series: 1, environment: :homologacao,
                     status: :assinada, total_value: 10 }.merge(overrides))
  end

  test 'is valid with company, number and series' do
    assert build_note.valid?
  end

  test 'access key must have 44 digits when present' do
    assert build_note(access_key: '3' * 44).valid?
    refute build_note(access_key: '123').valid?
  end

  test 'number is unique per company and series' do
    build_note.save!
    refute build_note.valid?
    assert build_note(series: 2).valid?
  end

  test 'active_for? is true while a draft, signed or authorized note exists for the order' do
    order = build_order
    assert_not FiscalNote.active_for?(order)

    note = build_note(b2b_order: order)
    note.save!
    assert FiscalNote.active_for?(order)

    %i[erro rejeitada cancelada].each do |status|
      note.update!(status: status)
      assert_not FiscalNote.active_for?(order), "#{status} should not block a new note"
    end

    note.update!(status: :autorizada)
    assert FiscalNote.active_for?(order)
  end

  test 'a company with notes cannot be destroyed' do
    build_note.save!
    assert_not @company.destroy
    assert @company.errors.any?
  end

  test 'xml_available? reflects the attachment' do
    note = build_note
    note.save!
    assert_not note.xml_available?
    note.xml.attach(io: StringIO.new('<NFe/>'), filename: 'nfe.xml', content_type: 'application/xml')
    assert note.xml_available?
  end

  def build_order
    user = User.create!(name: 'U', email: "u#{SecureRandom.hex(3)}@example.com", password: 'password123')
    client = Client.create!(responsible_name: 'Cliente')
    order = B2bOrder.new(kind: :sale, user: user, client: client)
    order.b2b_order_items.build(sku: 'S', quantity: 1, price: 1)
    order.save!
    order
  end
end
