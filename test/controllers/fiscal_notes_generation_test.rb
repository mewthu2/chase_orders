require 'test_helper'
require_relative '../support/nfe_test_certificate'

class FiscalNotesGenerationTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(name: 'Admin Gerar', email: 'admin_gerar@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @company = create_company
    @client = Client.create!(
      responsible_name: 'Fulano', business_name: 'Cliente Atacado Ltda', registration: '25.405.327/0001-74',
      state_registration: '111222333', ie_indicator: 1, street: 'Rua B', number: '20', neighbourhood: 'Bairro',
      city: 'Belo Horizonte', state: 'MG', zip: '31000-000', city_ibge_code: '3106200'
    )
    @location = TransferLocation.create!(
      name: 'CD Destino', registration: '45.723.174/0001-10', street: 'Rua C', number: '30', neighbourhood: 'Distrito',
      city: 'Contagem', state: 'MG', zip: '32000-000', city_ibge_code: '3118601'
    )
    Product.create!(sku: 'SKU-1', shopify_product_name: 'Camiseta', ncm: '61091000')
    @sale_nature = @company.operation_natures.create!(description: 'Venda de mercadoria', kind: :sale, cfop: '?102', final_consumer: false,
                                                      icms_situation: '102', pis_cst: '49', cofins_cst: '49')
    @transfer_nature = @company.operation_natures.create!(description: 'Transferência de mercadoria', kind: :transfer, cfop: '?152',
                                                          final_consumer: false, icms_situation: '102', pis_cst: '49', cofins_cst: '49')
    @sale = build_order(:sale)
    @transfer = build_order(:stock_transfer)
    sign_in @admin
  end

  def create_company(overrides = {})
    file = Tempfile.new(['cert', '.pfx'], binmode: true)
    file.write(NfeTestCertificate.pfx)
    file.rewind
    Company.create!({
      legal_name: 'Empresa Emissora Ltda', cnpj: '11.222.333/0001-81', state_registration: '123456789', tax_regime: 1,
      street: 'Rua A', number: '10', neighbourhood: 'Centro', city: 'Belo Horizonte', city_ibge_code: '3106200',
      state: 'MG', zip: '30000-000', certificate_file: Rack::Test::UploadedFile.new(file.path, 'application/x-pkcs12'),
      certificate_password: 'senha123'
    }.merge(overrides))
  end

  def build_order(kind, sku: 'SKU-1')
    attrs = kind == :sale ? { client: @client } : { transfer_location: @location, price_list: :transfer, receiver_name: 'Maria' }
    order = B2bOrder.new({ kind: kind, user: @admin }.merge(attrs))
    order.b2b_order_items.build(sku: sku, name: sku, quantity: 2, price: 10)
    order.save!
    order
  end

  test 'every B2B list links to the Nota fiscal tab of the order, with homologação and produção slots' do
    B2bSetting.current.update!(issuer_company: @company, sale_nature: @sale_nature)
    get b2b_orders_path
    assert_select "a[href='#{edit_b2b_order_path(@sale, tab: 'nota')}']"

    get stock_transfers_path
    assert_select "a[href='#{edit_stock_transfer_path(@transfer, tab: 'nota')}']"

    get edit_b2b_order_path(@sale, tab: 'nota')
    assert_select '[data-it-panel=nota]:not([hidden]) .it-fiscal-card'
    assert_select '.it-slot--homologacao'
    assert_select '.it-slot--producao'
  end

  test 'without fiscal_notes access there is no icon and the page is blocked' do
    profile = Profile.create!(name: 'So Pedidos')
    profile.update!(screen_keys: ['b2b_orders'])
    user = User.create!(name: 'So Pedidos', email: 'so_pedidos@example.com', password: 'password123')
    user.profiles << profile
    sign_in user

    get b2b_orders_path
    assert_select "a[href='#{new_fiscal_note_path(b2b_order_id: @sale.id)}']", count: 0

    get new_fiscal_note_path(b2b_order_id: @sale.id)
    assert_redirected_to root_path
  end

  test 'the old note page now opens the Nota fiscal tab of the order' do
    get new_fiscal_note_path(b2b_order_id: @sale.id)
    assert_redirected_to edit_b2b_order_path(@sale, tab: 'nota')

    get new_fiscal_note_path(b2b_order_id: @transfer.id)
    assert_redirected_to edit_stock_transfer_path(@transfer, tab: 'nota')
  end

  test 'create generates the signed note and redirects to it' do
    assert_difference 'FiscalNote.count', 1 do
      post fiscal_notes_path, params: { b2b_order_id: @sale.id, emission: "#{@company.id}:#{@sale_nature.id}" }
    end

    note = FiscalNote.last
    assert_redirected_to fiscal_note_path(note)
    assert note.assinada?
    assert note.xml_available?
    follow_redirect!
    assert_select '.flash-messages-container .alert', text: /transmita à SEFAZ/
  end

  test 'create works for a stock transfer too' do
    post fiscal_notes_path, params: { b2b_order_id: @transfer.id, emission: "#{@company.id}:#{@transfer_nature.id}" }

    assert_equal @transfer, FiscalNote.last.b2b_order
    assert_equal '5152', FiscalNote.last.cfop_summary
  end

  test 'create with missing fiscal data re-renders with the SKU listed and creates nothing' do
    order = build_order(:sale, sku: 'SEM-NCM')
    Product.create!(sku: 'SEM-NCM', shopify_product_name: 'Sem NCM')

    assert_no_difference 'FiscalNote.count' do
      post fiscal_notes_path, params: { b2b_order_id: order.id, emission: "#{@company.id}:#{@sale_nature.id}" }
    end

    assert_response :unprocessable_entity
    assert_select '.flash-messages-container .alert', text: /NCM do SKU SEM-NCM/
    assert_equal 1, @company.reload.next_nfe_number
  end

  test 'create refuses a company that is not ready' do
    @company.update_column(:active, false)

    assert_no_difference 'FiscalNote.count' do
      post fiscal_notes_path, params: { b2b_order_id: @sale.id, emission: "#{@company.id}:#{@sale_nature.id}" }
    end

    assert_response :unprocessable_entity
    assert_select '.flash-messages-container .alert', text: /empresa/i
  end

  test 'a second note for the same order is refused while the first is active' do
    post fiscal_notes_path, params: { b2b_order_id: @sale.id, emission: "#{@company.id}:#{@sale_nature.id}" }

    assert_no_difference 'FiscalNote.count' do
      post fiscal_notes_path, params: { b2b_order_id: @sale.id, emission: "#{@company.id}:#{@sale_nature.id}" }
    end
    assert_response :unprocessable_entity
    assert_select '.flash-messages-container .alert', text: /nota fiscal de .* ativa/
  end

  test 'an unknown order is a 404' do
    get new_fiscal_note_path(b2b_order_id: 0)

    assert_response :not_found
  end
end
