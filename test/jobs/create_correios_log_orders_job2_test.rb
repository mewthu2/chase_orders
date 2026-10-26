require 'test_helper'
require 'minitest/mock'

# Criação dos pedidos nos Correios B2B a partir dos pedidos do Tiny em preparando envio.
class CreateCorreiosLogOrdersJob2Test < ActiveSupport::TestCase
  def setup
    ENV['TOKEN_TINY2_PRODUCTION'] = 'fake-token'
    Tiny2OrderReview.create!(tiny_order_id: '902371809', status: :approved)
  end

  def tiny_pedido(**attrs)
    { pedido: {
      id: '902371809', data_pedido: '09/10/2026', numero_ecommerce: '', id_nota_fiscal: '44',
      cliente: { nome: 'CHASE BRASIL COMERCIO DE ARTIGOS ESPORTIVOS LTDA', email: '', endereco: 'Av. Raja Gabaglia', numero: '4343',
                 complemento: 'sala 419', bairro: 'Santa Lucia', cep: '30.350-577', cidade: 'Belo Horizonte', uf: 'MG',
                 fone: '', cpf_cnpj: '25.405.327/0003-36' },
      itens: [{ item: { codigo: 'leg-1659-m', quantidade: '14.00' } }]
    }.merge(attrs) }.with_indifferent_access
  end

  def run_job(pedido)
    sent = nil
    @recipient_name = nil
    job = CreateCorreiosLogOrdersJob2.new
    job.stub(:sleep, nil) do
      Tiny::Orders.stub(:obtain_order, pedido) do
        Correios::Orders.stub(:create_orders, ->(params, _attempt, recipient_name: nil) { sent = params; @recipient_name = recipient_name }) do
          job.create_one_log_order({ pedido: { id: '902371809' } }.with_indifferent_access)
        end
      end
    end
    sent
  end

  test 'a B2C transfer goes as transportadora (74926) with Chase as the carrier and no forma de frete' do
    params = run_job(tiny_pedido(obs: '(Transferencia b2c) | Transferência B2C #9', obs_interna: '(Transferencia b2c)'))

    assert_equal '74926', params[:forma_envio]
    assert_equal '25405327000336', params[:cnpj_transportadora]
    assert_nil params[:mao_propria]
    assert_equal [{ codigo: 'LEG-1659-M', quantidade: '14' }], params[:itens]
    assert_equal 'TRANSFERENCIA B2B PARA B2C', @recipient_name
    assert_equal 'CHASE BRASIL COMERCIO DE ARTIGOS ESPORTIVOS LTDA', params[:nome]
    assert Attempt.last.is_transportadora
  end

  test 'B2C transfers created with the old hand delivery tag or another carrier still go with Chase as the carrier' do
    params = run_job(tiny_pedido(obs: '(Transferencia b2c) | MAO PROPRIA | Transferência B2C #9', obs_interna: '(Transferencia b2c) MAO PROPRIA',
                                 forma_frete: 'Mix Cargo', nome_transportador: 'Mix Cargo'))

    assert_equal '74926', params[:forma_envio]
    assert_equal '25405327000336', params[:cnpj_transportadora]
    assert_nil params[:mao_propria]
  end

  test 'a store order by Mix Cargo goes as transportadora with the carrier CNPJ from the invoice' do
    invoice = { transportador: { cpf_cnpj: '11.222.333/0001-44' } }.with_indifferent_access
    params = Tiny::Invoices.stub(:obtain_invoice, invoice) do
      run_job(tiny_pedido(obs: 'Abastecimento loja', forma_frete: 'Mix Cargo', nome_transportador: 'Mix Cargo'))
    end

    assert_equal '74926', params[:forma_envio]
    assert_equal '11222333000144', params[:cnpj_transportadora]
    assert_nil params[:mao_propria]
    assert Attempt.last.is_transportadora
  end

  test 'a store to store order with the hand delivery tag goes by SEDEX with the hand delivery additional service' do
    params = run_job(tiny_pedido(obs: 'Abastecimento loja | MAO PROPRIA'))

    assert_equal '39888', params[:forma_envio]
    assert params[:mao_propria]
    assert_empty params[:cnpj_transportadora]
    assert_nil @recipient_name
    refute Attempt.last.is_transportadora
  end

  test 'a store supply order goes to Correios with the receiver as the recipient' do
    location = TransferLocation.create!(name: 'Loja Savassi', registration: '25.405.327/0001-74', street: 'Rua A',
                                        number: '1', neighbourhood: 'B', city: 'BH', state: 'MG', zip: '30000-000')
    user = User.create!(name: 'Teste Receb', email: 'teste_receb@example.com', password: 'password123')
    order = B2bOrder.new(kind: :stock_transfer, user:, transfer_location: location, receiver_name: 'Maria Souza',
                         tiny_reference_id: '902371809', tiny_reference_number: '1900')
    order.b2b_order_items.build(sku: 'SKU1', quantity: 1, price: 1)
    order.save!

    params = run_job(tiny_pedido(obs: 'MAO PROPRIA | Abastecimento Loja #1 | Responsável pelo recebimento: Maria Souza'))

    assert params[:mao_propria]
    assert_equal 'Maria Souza', @recipient_name
  end

  test 'a store supply order with several receivers sends the whole names that fit in 60 characters' do
    location = TransferLocation.create!(name: 'Loja Savassi', registration: '25.405.327/0001-74', street: 'Rua A',
                                        number: '1', neighbourhood: 'B', city: 'BH', state: 'MG', zip: '30000-000')
    user = User.create!(name: 'Teste Receb', email: 'teste_receb@example.com', password: 'password123')
    order = B2bOrder.new(kind: :stock_transfer, user:, transfer_location: location,
                         receiver_name: 'Maria Souza Andrade, João Pedro da Silva, Ana Beatriz Ferreira Lima',
                         tiny_reference_id: '902371809', tiny_reference_number: '1900')
    order.b2b_order_items.build(sku: 'SKU1', quantity: 1, price: 1)
    order.save!

    run_job(tiny_pedido(obs: 'MAO PROPRIA | Abastecimento Loja #1'))

    assert_equal 'Maria Souza Andrade, João Pedro da Silva', @recipient_name
  end

  test 'other orders keep using the forma de frete' do
    params = run_job(tiny_pedido(obs: 'Pedido B2B #10', forma_frete: 'PAC CORREIOS LOG+', nome_transportador: 'EMPRESA BRASILEIRA DE CORREIOS E TELEGRAFOS'))

    assert_equal '39870', params[:forma_envio]
    assert_nil params[:mao_propria]
    assert_equal 'CHASE BRASIL COMERCIO DE ARTIGOS ESPORTIVOS LTDA', params[:nome]
    assert_nil @recipient_name
  end

  test 'an order without forma de frete that is not hand delivery is still refused' do
    assert_nil run_job(tiny_pedido(obs: 'Pedido B2B #10'))
    assert_equal 'Forma de Envio não localizada', Attempt.last.error
  end
end
