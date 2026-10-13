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
    end
  end
end
