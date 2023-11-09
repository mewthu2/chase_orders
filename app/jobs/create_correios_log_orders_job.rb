class CreateCorreiosLogOrdersJob < ActiveJob::Base
  def perform(param, order)
    case param
    when 'all'
      create_correios_log_orders
    when 'one'
      create_one_log_order(order)
    end
  end

  def create_correios_log_orders
    orders = Tiny::Orders.get_orders('preparando_envio', 1)

    if orders[:numero_paginas].present?
      orders[:numero_paginas].times do |page|
        orders = Tiny::Orders.get_orders('preparando_envio', page)
        orders[:pedidos].each do |order|
          next unless order.present?
          next if Attempt.find_by(tiny_order_id: order[:pedido][:id], status: :success)

          create_one_log_order(order)
        end
      end
    else
      orders[:pedidos].each do |order|
        next unless order.present?
        next if Attempt.find_by(tiny_order_id: order[:pedido][:id], status: :success)
        create_one_log_order(order)
      end
    end
  end

  def create_one_log_order(order)
    params = {
      invoice: '',
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
      selected_order = Tiny::Orders.obtain_order(order[:pedido][:id])
    rescue StandardError => e
      attempt.update(error: e, status: :error)
    end

    p 'Sleeping 3 seconds'
    sleep(3)
    p 'Waking Up, and get back to work!'

    # Obtain invoice number
    begin
      invoice = Tiny::Invoices.obtain_invoice(selected_order[:pedido][:id_nota_fiscal])
    rescue StandardError => e
      attempt.update(error: e, status: :error)
    end

    # Verify order founded
    attempt.update(error: "Order - #{order[:pedido][:id]} não encontrada", status: :error) unless selected_order.present?

    # Verifying client data after continue
    attempt.update(error: 'Dados do Cliente não disponíveis', status: :error) unless selected_order[:pedido][:cliente].present?

    # Find client data on selected order hash
    client_data = selected_order[:pedido][:cliente]

    # Some 'total_pedido' have a zero value, reasoned by discount
    if selected_order[:pedido][:total_pedido] > selected_order[:pedido][:total_produtos]
      assert_value = selected_order[:pedido][:total_pedido]
    else
      assert_value = selected_order[:pedido][:total_produtos]
    end

    # assert ecommerce
    if selected_order[:pedido][:numero_ecommerce].present?
      ecommerce_number = selected_order[:pedido][:numero_ecommerce]
    else
      ecommerce_number = '0'
    end

    # Setting founded valures
    begin
      params[:invoice]          << invoice[:numero].sub!(/^0/, '')
      params[:numero_ecommerce] << ecommerce_number
      params[:data_pedido]      << selected_order[:pedido][:data_pedido]
      params[:valor]            << assert_value
      params[:nome]             << client_data[:nome]
      params[:endereco]         << client_data[:endereco]
      params[:numero]           << client_data[:numero]
      params[:complemento]      << client_data[:complemento]
      params[:bairro]           << client_data[:bairro]
      params[:cep]              << client_data[:cep].gsub('.', '').gsub('-', '')
      params[:cidade]           << client_data[:cidade]
      params[:uf]               << client_data[:uf]
      params[:fone]             << client_data[:fone]
      params[:email]            << client_data[:email]
      params[:cpf_cnpj]         << client_data[:cpf_cnpj].gsub('.', '').gsub('-', '')
      params[:pedido_id]        << selected_order[:pedido][:id]

      # Form items array
      order_items = selected_order[:pedido][:itens]
      p 'PASSOU 8'
      order_items.each do |oi|
        params[:itens] << { codigo: oi[:item][:codigo].upcase, quantidade: oi[:item][:quantidade].sub(/\.?0*\z/, '') }
      end
      p 'PASSOU 9'
      attempt.update(params:)
      attempt.update(id_nota_fiscal: selected_order[:pedido][:id_nota_fiscal].to_i)
      p 'PASSOU 10'
      verify_params(attempt, params)

    rescue StandardError => e
      attempt.update(error: e, status: :error)
    end

    # Create Order in Correios Log +
    Correios::Orders.create_orders(params, attempt) unless attempt.error.present?
  end

  def verify_params(attempt, params)
    required_params = [:data_pedido, :valor, :nome, :endereco, :numero, :bairro, :cep, :cidade, :uf, :email, :cpf_cnpj, :invoice]

    missing_params = required_params.select { |param| params[param] == '' }

    return unless missing_params.any?
    error_message = "#{missing_params.join(', ')} não presente"
    attempt.update(error: error_message)
  end
end