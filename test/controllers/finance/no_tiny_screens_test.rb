require 'test_helper'

# Pedidos do Tiny não existem mais: as telas do atacado e do Log02 não mostram número nem textos do Tiny.
class Finance::NoTinyScreensTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(name: 'Admin NT', email: 'admin_nt@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    client = Client.create!(responsible_name: 'Cliente NT', registration: '25.405.327/0001-74')
    o = B2bOrder.new(kind: :sale, user: @admin, client: client, payment_method: 'pix', salesperson_name: 'Ana')
    o.b2b_order_items.build(sku: 'S', name: 'P', quantity: 1, price: 10)
    o.save!(validate: false)
    sign_in @admin
  end

  def page_text = Nokogiri::HTML(response.body).css('main, .pg-blocks, .callout').text

  test 'listas de atacado, abastecimento e transferencia sem Tiny' do
    [b2b_orders_path, stock_transfers_path, b2c_transfers_path].each do |path|
      get path
      assert_response :success
      assert_no_match(/Tiny/, page_text, path)
    end
  end

  test 'lista de atacado mostra o consultor com pendencia' do
    get b2b_orders_path
    assert_select 'th', text: 'Consultor'
    assert_match 'cadastro pendente', response.body
  end

  test 'filas do Log02 sem Tiny' do
    %w[order_correios_create_b2b order_correios_create_queue_b2b send_xml_b2b push_tracking_b2b order_correios_tracking_b2b].each do |action|
      get "/dashboard/#{action}"
      assert_response :success, action
      assert_no_match(/Tiny/, page_text, action)
    end
  end
end
