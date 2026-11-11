require 'test_helper'
require 'minitest/mock'

# Telas API Correios com Turbo + Stimulus: o rastreio responde num Turbo Frame (HTML) e o resto da
# tela é ligado pelos controllers Stimulus; quem pede JSON continua recebendo JSON.
class ApiCorreiosHotwireTest < ActionDispatch::IntegrationTest
  FakeResponse = Struct.new(:code, :body_hash) do
    def [](key) = body_hash[key]
  end

  def setup
    @admin = User.create!(name: 'Admin Correios', email: 'admin_correios_hotwire@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    sign_in @admin
  end

  def with_tracking(response, &)
    Correios::Orders.stub(:get_tracking, ->(*_args, **_kwargs) { response }, &)
  end

  test 'o rastreio pedido pelo Turbo Frame volta como HTML do frame' do
    with_tracking(FakeResponse.new(200, { 'rastreio' => [{ 'codigoObjeto' => 'AB123456789BR' }] })) do
      get tracking_dashboard_index_path(tracking_number: '58213', b2b: 0), headers: { 'Turbo-Frame' => 'tracking_lookup' }
    end

    assert_response :success
    assert_select 'turbo-frame#tracking_lookup .pg-answer', text: /AB123456789BR/
  end

  test 'sem código de rastreio o frame diz que não achou' do
    with_tracking(FakeResponse.new(404, {})) do
      get tracking_dashboard_index_path(tracking_number: '1', b2b: 1), headers: { 'Turbo-Frame' => 'tracking_lookup' }
    end

    assert_response :success
    assert_select 'turbo-frame#tracking_lookup', text: /Nenhum resultado encontrado/
  end

  test 'fora do Turbo Frame o rastreio continua em JSON' do
    with_tracking(FakeResponse.new(200, { 'rastreio' => [{ 'codigoObjeto' => 'AB123456789BR' }] })) do
      get tracking_dashboard_index_path(tracking_number: '58213', b2b: 0), as: :json
    end

    assert_response :success
    assert_equal 'AB123456789BR', response.parsed_body.first['codigoObjeto']
  end

  test 'as duas telas trazem os controllers Stimulus, o frame do rastreio e o modal do lote' do
    { api_correios_dashboard_index_path => ['false', 'Estoque B2B (Log02)', api_correios_b2b_dashboard_index_path],
      api_correios_b2b_dashboard_index_path => ['true', 'Estoque B2C (Log03)', api_correios_dashboard_index_path] }.each do |path, (b2b, other_label, cross_url)|
      get path
      assert_response :success, path
      assert_select 'script[type="importmap"]', 1
      assert_select %([data-controller="stock-lookup"][data-stock-lookup-b2b-value="#{b2b}"][data-stock-lookup-cross-url-value="#{cross_url}"])
      assert_select 'form[data-turbo="true"][data-turbo-frame="tracking_lookup"] input[name="tracking_number"][required]'
      assert_select 'turbo-frame#tracking_lookup'
      assert_select '#bulkStockModal[data-controller="modal dropzone bulk-stock"]'
      assert_select '#bulkStockModal thead th', text: other_label
      assert_select '[data-controller="modal-opener"][data-modal-opener-modal-outlet="#bulkStockModal"]'
      assert_select 'script', { text: /\$\(document\)\.ready/, count: 0 }, 'o script jQuery antigo da tela saiu'
    end
  end
end
