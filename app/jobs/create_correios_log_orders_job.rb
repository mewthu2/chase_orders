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
        next unless order.present?
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
      bairro: '',
      cep: '',
      cidade: '',
      uf: '',
      fone: '',
      email: '',
      cpf_cnpj: '',
      pedido_id: '',
      itens: []
    }

    # Create Attempt
    attempt = Attempt.create!(kinds: :create_correios_order,
                              tiny_order_id: order[:pedido][:id])

    # Obtain more info from a specific order
    begin
      selected_order = Tiny::Orders.obtain_order('800705459')
    rescue StandardError => e
      attempt.update(error: e, status: :error)
    end

    # Verify order founded
    attempt.update(error: "Order - #{order[:pedido][:id]} não encontrada", status: :error) unless selected_order.present?

    # Verifying client data after continue
    attempt.update(error: 'Dados do Cliente não disponíveis', status: :error) unless selected_order[:pedido][:cliente].present?

    client_data = selected_order[:pedido][:cliente]

    begin
      params[:numero_ecommerce] << selected_order[:pedido][:numero_ecommerce]
      params[:data_pedido]      << selected_order[:pedido][:data_pedido]
      params[:valor]            << selected_order[:pedido][:total_pedido]
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
      params[:cpf_cnpj]         << client_data[:cpf_cnpj].gsub('.', '').gsub('-', '')
      params[:pedido_id]        << selected_order[:pedido][:id]

      # Form items array
      order_items = selected_order[:pedido][:itens]
      itens = []

      order_items.each do |oi|
        itens << { 'codigo' => oi[:item][:codigo].upcase, 'quantidade' => oi[:item][:quantidade].sub(/\.?0*\z/, '') }
      end
      params[:itens] << itens
      attempt.update(params: params)

      verify_params(attempt, params)

    rescue StandardError => e
      attempt.update(error: e, status: :error)
    end

    # Create Order in Correios Log +
    Correios::Orders.create_orders(params, attempt) if !attempt.error.present? || params[:pedido].present?
  end

  def verify_params(attempt, params)
    required_params = [:numero_ecommerce, :data_pedido, :valor, :nome, :endereco, :numero,
                       :complemento, :bairro, :cep, :cidade, :uf, :fone, :email, :cpf_cnpj]

    missing_params = required_params.select { |param| params[param].nil? }

    return unless missing_params.any?
    error_message = "#{missing_params.join(', ')} não presente"
    attempt.update(error: error_message)
  end
end
