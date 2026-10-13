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

  test 'a hand delivery (B2C transfer) order goes to Correios with forma_envio 002 and no forma de frete' do
    params = run_job(tiny_pedido(obs: '(Transferencia b2c) | MAO PROPRIA | Transferência B2C #9', obs_interna: '(Transferencia b2c) MAO PROPRIA'))

    assert_equal '002', params[:forma_envio]
    assert_equal '', params[:cnpj_transportadora]
    assert_equal [{ codigo: 'LEG-1659-M', quantidade: '14' }], params[:itens]
    assert_equal 'TRANSFERENCIA B2B PARA B2C', @recipient_name
    assert_equal 'CHASE BRASIL COMERCIO DE ARTIGOS ESPORTIVOS LTDA', params[:nome]
    refute Attempt.last.is_transportadora
  end

  test 'B2C transfers sent before the hand delivery tag are recognised by the transfer tag' do
    params = run_job(tiny_pedido(obs: '(Transferencia b2c) | Transferência B2C #9', obs_interna: '(Transferencia b2c)',
                                 forma_frete: 'Mix Cargo', nome_transportador: 'Mix Cargo'))

    assert_equal '002', params[:forma_envio]
    assert_equal '', params[:cnpj_transportadora]
  end

  test 'other orders keep using the forma de frete' do
    params = run_job(tiny_pedido(obs: 'Pedido B2B #10', forma_frete: 'PAC CORREIOS LOG+', nome_transportador: 'EMPRESA BRASILEIRA DE CORREIOS E TELEGRAFOS'))

    assert_equal '39870', params[:forma_envio]
    assert_equal 'CHASE BRASIL COMERCIO DE ARTIGOS ESPORTIVOS LTDA', params[:nome]
    assert_nil @recipient_name
  end

  test 'an order without forma de frete that is not hand delivery is still refused' do
    assert_nil run_job(tiny_pedido(obs: 'Pedido B2B #10'))
    assert_equal 'Forma de Envio não localizada', Attempt.last.error
  end
end
