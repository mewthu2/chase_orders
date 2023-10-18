class CreateCorreiosLogOrdersJob < ActiveJob::Base
  def perform(param)
    case param
    when 'all'
      create_correios_log_orders
    when 'one'
      create_one_log_order(params)
    end
  end

  def create_correios_log_orders
    orders = Tiny::Orders.get_orders('preparando_envio', 1)

    orders[:numero_paginas].times do |page|
      orders = Tiny::Orders.get_orders('preparando_envio', page)
      orders[:pedidos].each do |order|
        create_one_log_order(order)
      end
    end
  end

  def create_one_log_order(order)
    params = {
      numero_ecommerce: '',
      data_pedido: '',
      valor: '',
      nome: '',
      endereco: '',
      numero: '',
      complemento: '',
      itens: nil
    }

    # Obtain more info from a specific order
    selected_order = Tiny::Orders.obtain_order(order[:pedido][:id])
    client_data = selected_order[:pedido][:cliente]

    params[:numero_ecommerce] << selected_order[:pedido][:numero_ecommerce]
    params[:data_pedido]      << selected_order[:pedido][:data_pedido]
    params[:valor]            << selected_order[:pedido][:valor]
    params[:nome]             << client_data[:nome]
    params[:endereco]         << client_data[:endereco]
    params[:numero]           << client_data[:numero]
    params[:complemento]      << client_data[:complemento]
    params[:bairro]           << client_data[:bairro]
    params[:cep]              << client_data[:cep]
    params[:cidade]           << client_data[:cidade]
    params[:uf]               << client_data[:uf]
    params[:fone]             << client_data[:fone]
    params[:email]            << client_data[:email]
    params[:cpf_cnpj]         << client_data[:cpf_cnpj]

    # Form items array
    order_items = selected_order[:pedido][:itens]
    itens = []

    order_items.each do |oi|
      itens << { 'codigo' => oi[:item][:codigo].upcase, 'quantidade' => oi[:item][:quantidade].sub(/\.?0*\z/, '') }
    end

    params[:itens] << itens

    # Create Order in Correios Log +
    Correios::Orders.create_orders(params)
  end
end
