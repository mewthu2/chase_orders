require 'test_helper'

# Telas da fila (emissão de nota e envio de XML, B2B e B2C) sempre mostram o nome do cliente.
class DashboardCustomerNameTest < ActionDispatch::IntegrationTest
  def setup
    ENV['TINY_SELLS_URL'] = 'https://erp.tiny.com.br/vendas'
    @admin = User.create!(name: 'Admin Clientes', email: 'admin_clientes@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    sign_in @admin
  end

  def created(kind, tiny_order_id, nome)
    Attempt.create!(kinds: kind, status: :success, tiny_order_id:, order_correios_id: tiny_order_id + 5, id_nota_fiscal: tiny_order_id + 9,
                    params: { invoice: tiny_order_id.to_s, nome:, cpf_cnpj: '123' }.inspect)
  end

  {
    invoice_emition: [:create_correios_order, :invoice_emition_dashboard_index_path, nil],
    invoice_emition_b2b: [:create_correios_order_tiny2, :invoice_emition_b2b_dashboard_index_path, nil],
    send_xml: [:create_correios_order, :send_xml_dashboard_index_path, :emission_invoice],
    send_xml_b2b: [:create_correios_order_tiny2, :send_xml_b2b_dashboard_index_path, :emission_invoice_tiny2]
  }.each do |screen, (kind, path, invoiced_kind)|
    test "#{screen} shows the customer name next to the other order data" do
      created(kind, 4100, 'Maria Conceição')
      # O envio de XML só lista pedidos com a nota já emitida.
      Attempt.create!(kinds: invoiced_kind, status: :success, tiny_order_id: 4100, order_correios_id: 4105) if invoiced_kind

      get public_send(path)

      assert_response :success
      assert_select 'th', text: /Cliente/
      assert_select '.customer-name-cell', text: /Maria Conceição/
      assert_match(/4105/, response.body, 'o ID do Correios continua aparecendo')
      assert_select 'tbody .b2b-order-type-badge', text: /B2B Comum/, count: screen.to_s.end_with?('_b2b') ? 1 : 0
    end
  end

  test 'send_xml_b2b filters by order type with chips in the badge layout' do
    store = TransferLocation.create!(name: 'Loja Savassi', registration: '25.405.327/0005-06', street: 'Rua A', number: '1',
                                     neighbourhood: 'Savassi', city: 'Belo Horizonte', state: 'MG', zip: '30140-000')
    { 4100 => '11222333000144', 4200 => '25405327000336', 4300 => store.registration.delete('^0-9') }.each do |id, cnpj|
      Attempt.create!(kinds: :create_correios_order_tiny2, status: :success, tiny_order_id: id, order_correios_id: id + 5,
                      id_nota_fiscal: id + 9, params: { invoice: id.to_s, nome: "Cliente #{id}", cpf_cnpj: cnpj }.inspect)
      Attempt.create!(kinds: :emission_invoice_tiny2, status: :success, tiny_order_id: id, order_correios_id: id + 5)
    end

    get send_xml_b2b_dashboard_index_path
    assert_select 'tbody tr', count: 3
    assert_select 'a.order-type-chip.is-active', text: /Todos\s*3/
    assert_select 'a.order-type-chip.b2b-order-type-badge.type-b2c_transfer', text: /Transferência B2B → B2C\s*1/

    get send_xml_b2b_dashboard_index_path(order_type: 'b2c_transfer', transportadora: 'correios')
    assert_select 'a.order-type-chip.type-b2c_transfer.is-active'
    assert_select "a.order-type-chip--all[href*='transportadora=correios']"
    assert_select 'input[type=hidden][name=order_type][value=b2c_transfer]'

    get send_xml_b2b_dashboard_index_path(order_type: 'store_supply')
    assert_select 'tbody tr', count: 1
    assert_select '.customer-name-cell', text: /Cliente 4300/

    get send_xml_b2b_dashboard_index_path(order_type: 'invalido')
    assert_select 'tbody tr', count: 3
  end
end
