require 'test_helper'
require 'webmock/minitest'

class OrderCorreiosCreateTinyErrorTest < ActionDispatch::IntegrationTest
  SEARCH_URL = 'https://tiny.example.com/pedidos.pesquisa.php'.freeze

  setup do
    ENV['PEDIDOS_PESQUISA'] = SEARCH_URL
    ENV['TOKEN_TINY3_PRODUCTION'] = 'tiny3'
    @admin = User.create!(name: 'Admin Correios', email: 'admin_correios_b2c@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    sign_in @admin
  end

  test 'shows the Tiny error instead of an empty list without explanation' do
    stub_request(:get, /pedidos\.pesquisa/).to_return(body: { retorno: { status: 'Erro', codigo_erro: '2', erros: [{ erro: 'token inválido' }] } }.to_json)

    get order_correios_create_dashboard_index_path

    assert_response :success
    assert_select '.alert-danger', text: /token inválido/
  end

  test 'lists the orders of every page and shows no error' do
    stub_request(:get, SEARCH_URL).with(query: hash_including(pagina: '1'))
      .to_return(body: { retorno: { status: 'OK', numero_paginas: 2, pedidos: [{ pedido: { id: '501', numero: '9501', nome: 'Pagina Um', data_pedido: '10/10/2026', valor: '10' } }] } }.to_json)
    stub_request(:get, SEARCH_URL).with(query: hash_including(pagina: '2'))
      .to_return(body: { retorno: { status: 'OK', numero_paginas: 2, pedidos: [{ pedido: { id: '502', numero: '9502', nome: 'Pagina Dois', data_pedido: '10/10/2026', valor: '10' } }] } }.to_json)

    get order_correios_create_dashboard_index_path

    assert_response :success
    assert_select '.alert-danger', count: 0
    assert_match(/Pagina Um/, response.body)
    assert_match(/Pagina Dois/, response.body)
  end
end
