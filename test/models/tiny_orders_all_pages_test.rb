require 'test_helper'
require 'webmock/minitest'

class TinyOrdersAllPagesTest < ActiveSupport::TestCase
  SEARCH_URL = 'https://tiny.example.com/pedidos.pesquisa.php'.freeze

  setup { ENV['PEDIDOS_PESQUISA'] = SEARCH_URL }

  def stub_page(page, ids, pages: 2)
    stub_request(:get, SEARCH_URL).with(query: hash_including(pagina: page.to_s))
      .to_return(body: { retorno: { status: 'OK', numero_paginas: pages, pedidos: ids.map { |id| { pedido: { id: id.to_s } } } } }.to_json)
  end

  test 'joins the orders of every page' do
    stub_page(1, [1, 2])
    stub_page(2, [3])

    retorno = Tiny::Orders.get_all_orders_response('preparando_envio', 'tok', '01/10/2026')

    assert_equal 'OK', retorno[:status]
    assert_equal %w[1 2 3], retorno[:pedidos].map { |entry| entry[:pedido][:id] }
  end

  test 'returns the Tiny error untouched so the screen can show it' do
    stub_request(:get, /pedidos\.pesquisa/).to_return(body: { retorno: { status: 'Erro', erros: [{ erro: 'token inválido' }] } }.to_json)

    retorno = Tiny::Orders.get_all_orders_response('preparando_envio', 'tok', '01/10/2026')

    assert_equal 'Erro', retorno[:status]
    assert_requested :get, /pedidos\.pesquisa/, times: 1
  end
end
