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

  test 'purpose: e-commerce, wholesale, transfer and loose notes' do
    assert_equal 'ecommerce', build_note(shopify_order_name: '#1234').purpose
    assert_equal 'atacado', build_note(b2b_order: build_order).purpose
    assert_equal 'transferencia', build_note(b2b_order: build_order(kind: :stock_transfer)).purpose
    assert_equal 'transferencia', build_note(b2b_order: build_order(kind: :b2c_transfer)).purpose
    assert_equal 'avulsa', build_note.purpose
    assert_equal 'transferencia', build_note(nature: build_nature(kind: :transfer)).purpose
  end

  test 'purpose: return, complementary and adjustment natures win over the source order' do
    assert_equal 'devolucao', build_note(shopify_order_name: '#1', nature: build_nature(purpose: 4)).purpose
    assert_equal 'complementar', build_note(nature: build_nature(purpose: 2)).purpose
    assert_equal 'ajuste', build_note(nature: build_nature(purpose: 3)).purpose
  end

  test 'every purpose has a label' do
    assert_equal FiscalNote::PURPOSES.keys.sort, %w[ajuste atacado avulsa complementar devolucao ecommerce transferencia]
    assert_equal 'Pedido do e-commerce', build_note(shopify_order_name: '#1').purpose_label
  end

  test 'with_purpose filters the same way purpose classifies' do
    notes = {
      'ecommerce' => build_note(number: 1, shopify_order_name: '#1'),
      'atacado' => build_note(number: 2, b2b_order: build_order),
      'transferencia' => build_note(number: 3, b2b_order: build_order(kind: :stock_transfer)),
      'devolucao' => build_note(number: 4, shopify_order_name: '#2', nature: build_nature(purpose: 4)),
      'avulsa' => build_note(number: 5, nature: build_nature)
    }
    notes.each_value(&:save!)
    notes.each do |key, note|
      assert_equal note.purpose, key
      assert_equal [note.id], FiscalNote.with_purpose(key).pluck(:id), "with_purpose(#{key})"
    end
    assert_empty FiscalNote.with_purpose('nao-existe')
  end

  def build_nature(kind: :sale, purpose: 1)
    nature = OperationNature.new(company: @company, description: 'Natureza', kind: kind, purpose: purpose, cfop: '?102')
    nature.save!(validate: false)
    nature
  end

  def build_order(kind: :sale)
    user = User.create!(name: 'U', email: "u#{SecureRandom.hex(3)}@example.com", password: 'password123')
    client = Client.create!(responsible_name: 'Cliente')
    order = B2bOrder.new(kind: kind, user: user, client: client)
    order.b2b_order_items.build(sku: 'S', quantity: 1, price: 1)
    order.save!(validate: kind == :sale)
    order
  end
end
