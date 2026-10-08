require 'test_helper'
require 'webmock/minitest'

# Transferência B2B -> B2C: pedido no Tiny B2B no mesmo formato do pedido nº 1859 (lista e natureza
# Transferencia, destinatário fixo na filial B2C, marcador "(Transferencia b2c)") e já em
# "preparando_envio", para cair na fila de criação dos Correios B2B.
class B2bTinyServiceB2cTransferTest < ActiveSupport::TestCase
  PEDIDO_URL = 'https://api.tiny.com.br/api2/pedido.incluir.php'.freeze
  FORMAS_URL = 'https://api.tiny.com.br/api2/formas.envio.pesquisa.php'.freeze

  def setup
    ENV['TOKEN_TINY2_PRODUCTION'] = 'fake-token'
    @user = User.create!(name: 'Teste B2C', email: 'teste_b2c@example.com', password: 'password123')
    @carrier = Carrier.create!(name: 'Mix Cargo', registration: '25.405.327/0001-74', street: 'Rua C', number: '1',
                              neighbourhood: 'B', city: 'BH', state: 'MG', zip: '30000-000')
    stub_request(:get, FORMAS_URL).with(query: hash_including('formato' => 'json')).to_return(body: { retorno: { status: 'OK', registros: [
      { id: '782947860', nome: 'Transportadora', situacao: '1', tipo_logistica: '2' }
    ] } }.to_json)
  end

  def build_order(**attrs)
    order = B2bOrder.new({ kind: :b2c_transfer, user: @user, price_list: :transfer,
                           carrier_shipping_method: '782947860', carrier: @carrier, notes: 'Reposição site' }.merge(attrs))
    order.b2b_order_items.build(sku: 'LEG-1659-M', name: 'Legging Pure Seamless Tibetan Red M', quantity: 14, price: 21.96)
    order.save!
    order
  end

  def sent_pedido
    pedido = nil
    stub_request(:post, PEDIDO_URL).with do |req|
      pedido = JSON.parse(URI.decode_www_form(req.body).to_h['pedido'])['pedido']
      true
    end.to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '902371809', numero: '1859' } } } }.to_json)
    yield
    pedido
  end

  test 'creates the order in Tiny following the B2C transfer pattern' do
    order = build_order
    result = nil
    pedido = sent_pedido { result = B2bTinyService.new.create_b2c_transfer(order) }

    assert result[:success]
    assert_equal '902371809', result[:tiny_reference_id]
    assert_equal '1859', result[:tiny_reference_number]

    assert_equal 'preparando_envio', pedido['situacao']
    assert_equal '8198', pedido['id_lista_preco']
    assert_equal '790850411', pedido['id_natureza_operacao']

    assert_equal 'CHASE BRASIL COMERCIO DE ARTIGOS ESPORTIVOS LTDA', pedido['cliente']['nome']
    assert_equal '25.405.327/0003-36', pedido['cliente']['cpf_cnpj']
    assert_equal '0029090240268', pedido['cliente']['ie']
    assert_equal 'MG', pedido['cliente']['uf']

    assert_equal '(Transferencia b2c)', pedido['endereco_entrega']['nome_destinatario']
    assert_equal '25.405.327/0003-36', pedido['endereco_entrega']['cpf_cnpj']
    assert_equal [{ 'marcador' => { 'id' => '182662', 'descricao' => '(Transferencia b2c)' } }], pedido['marcadores']
    assert_equal '(Transferencia b2c)', pedido['obs_interna']
    assert_includes pedido['obs'], '(Transferencia b2c)'
    assert_includes pedido['obs'], 'Reposição site'

    assert_equal 'T', pedido['forma_envio']
    assert_equal 'Mix Cargo', pedido['nome_transportador']
    assert_equal 'Mix Cargo', pedido['forma_frete']
    item = pedido['itens'].first['item']
    assert_equal 'LEG-1659-M', item['codigo']
    assert_equal 14, item['quantidade']
  end

  test 'returns the Tiny error message when Tiny rejects the order' do
    order = build_order
    stub_request(:post, PEDIDO_URL)
      .to_return(body: { retorno: { status: 'Erro', erros: { erro: 'Produto não encontrado' } } }.to_json)

    result = B2bTinyService.new.create_b2c_transfer(order)
    refute result[:success]
    assert_equal 'Produto não encontrado', result[:error]
  end

  test 'a B2C transfer needs a shipping method' do
    order = B2bOrder.new(kind: :b2c_transfer, user: @user, price_list: :transfer)
    order.b2b_order_items.build(sku: 'LEG-1659-M', name: 'Legging', quantity: 1, price: 21.96)

    refute order.valid?
    assert_includes order.errors.full_messages, 'Escolha a forma de envio da transferência B2C.'
  end
end
