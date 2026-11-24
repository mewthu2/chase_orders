require 'test_helper'
require 'zip'

# Notas Fiscais do Atacado e da Logística: só as notas da área, por mês (o atual por padrão), o valor das
# notas ativas do filtro, a seleção e o ZIP dos XML.
class FiscalNoteListsTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(name: 'Admin Notas', email: 'admin_fnl@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @company = Company.new(legal_name: 'Emissora', cnpj: '11.222.333/0001-81', street: 'R', number: '1', neighbourhood: 'B', city: 'BH',
                           city_ibge_code: '3106200', state: 'MG', zip: '30000000')
    @company.save!(validate: false)
    @client = Client.create!(responsible_name: 'Lojista Notas', registration: '25.405.327/0001-74')
    @number = 100
    sign_in @admin
  end

  def order(kind, **attrs)
    o = B2bOrder.new({ kind: kind, user: @admin }.merge(attrs))
    o.client = @client if kind == :sale
    o.transfer_direction = :b2b_to_b2c if kind == :b2c_transfer
    o.b2b_order_items.build(sku: 'SKU1', name: 'Legging', quantity: 1, price: 10)
    o.save!(validate: false)
    o
  end

  def note(b2b_order, status: :autorizada, value: 100, at: Time.current, environment: :producao, role: nil, xml: true)
    @number += 1
    n = FiscalNote.create!(company: @company, b2b_order: b2b_order, number: @number, series: 1, environment: environment, status: status,
                           total_value: value, issued_at: at, role: role, access_key: format('%044d', @number))
    n.xml.attach(io: StringIO.new("<nfeProc>#{@number}</nfeProc>"), filename: 'n.xml', content_type: 'application/xml') if xml
    n
  end

  def zip_entries(body)
    names = []
    Zip::InputStream.open(StringIO.new(body)) { |io| while (entry = io.get_next_entry) do names << entry.name end }
    names
  end

  test 'Atacado shows only the sale notes of the current month, in production, with the active value of the filter' do
    sale = note(order(:sale), value: 150)
    note(order(:sale), status: :cancelada, value: 999)
    note(order(:sale), value: 70, at: 2.months.ago)
    note(order(:sale), value: 500, environment: :homologacao)
    transfer = note(order(:stock_transfer), value: 300)

    get wholesale_fiscal_notes_path

    assert_response :success
    assert_select "tr[data-pg-row='#{sale.id}']"
    assert_select "tr[data-pg-row='#{transfer.id}']", count: 0
    assert_select '.pg-kpi', text: /Notas no filtro\s*2/
    assert_select '.pg-kpi', text: /Valor das notas ativas\s*R\$\s*150,00/
    assert_select ".pg-month select option[selected][value='#{Date.current.strftime('%Y-%m')}']"
    assert_select "input.row-select-checkbox[data-id='#{sale.id}'][data-value='150.0'][data-active='true']"
  end

  test 'the month arrows and "all months" change the period' do
    old = note(order(:sale), value: 70, at: 2.months.ago)

    get wholesale_fiscal_notes_path(mes: 2.months.ago.strftime('%Y-%m'))
    assert_select "tr[data-pg-row='#{old.id}']"
    assert_select '.pg-kpi', text: /R\$\s*70,00/
    assert_select ".pg-month-nav[href*='mes=#{1.month.ago.strftime('%Y-%m')}']"

    get wholesale_fiscal_notes_path(mes: 'todos', amb: 'todos')
    assert_select "tr[data-pg-row='#{old.id}']"
  end

  test 'Logística has the store supply and B2B ⇄ B2C notes, with the remessa, filtered by type' do
    supply = note(order(:stock_transfer))
    transfer_order = order(:b2c_transfer)
    transfer = note(transfer_order)
    remessa = note(transfer_order, role: 'remessa')
    sale = note(order(:sale))

    get logistics_fiscal_notes_path
    assert_response :success
    [supply, transfer, remessa].each { |n| assert_select "tr[data-pg-row='#{n.id}']" }
    assert_select "tr[data-pg-row='#{sale.id}']", count: 0

    get logistics_fiscal_notes_path(tipo: 'remessa')
    assert_select "tr[data-pg-row='#{remessa.id}']"
    assert_select "tr[data-pg-row='#{transfer.id}']", count: 0
  end

  test 'the ZIP has the XML of the authorized and canceled notes of the filter, or only the selected ones' do
    a = note(order(:sale))
    b = note(order(:sale))
    canceled = note(order(:sale), status: :cancelada)
    canceled.cancel_xml.attach(io: StringIO.new('<procEventoNFe/>'), filename: 'c.xml', content_type: 'application/xml')
    note(order(:sale), status: :rascunho)
    note(order(:sale), at: 2.months.ago)

    get xmls_wholesale_fiscal_notes_path
    assert_response :success
    assert_equal 'application/zip', response.media_type
    assert_equal ["NFe#{a.access_key}.xml", "NFe#{b.access_key}.xml", "NFe#{canceled.access_key}.xml", "NFe#{canceled.access_key}-cancelamento.xml"],
                 zip_entries(response.body)

    get xmls_wholesale_fiscal_notes_path(ids: [b.id])
    assert_equal ["NFe#{b.access_key}.xml"], zip_entries(response.body)
  end

  test 'without notes with XML, the ZIP goes back with a message' do
    note(order(:sale), status: :rascunho)

    get xmls_wholesale_fiscal_notes_path
    assert_redirected_to wholesale_fiscal_notes_path
  end

  test 'the menu shows each list by the area permission' do
    profile = Profile.create!(name: "Logística #{SecureRandom.hex(3)}")
    profile.update!(screen_keys: ['b2b_transfers'])
    user = User.create!(name: 'Log', email: "log_#{SecureRandom.hex(3)}@example.com", password: 'password123').tap { |u| u.profiles << profile }
    sign_in user

    get logistics_fiscal_notes_path
    assert_response :success
    assert_select ".sb-link[href='#{logistics_fiscal_notes_path}']"
    assert_select ".sb-link[href='#{wholesale_fiscal_notes_path}']", count: 0

    get wholesale_fiscal_notes_path
    assert_response :redirect
  end
end
