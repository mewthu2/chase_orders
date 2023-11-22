class CreateCorreiosLogOrdersJob < ActiveJob::Base
  queue_as :default
  include ApplicationHelper

  def perform(param, order)
    return unless verify_comercial_hour?
    case param
    when 'all'
      create_correios_log_orders
    when 'one'
      create_one_log_order(order)
    end
  end

  def create_correios_log_orders
    page = 1
    orders = Tiny::Orders.get_orders('preparando_envio', page)

    while orders[:numero_paginas].present? && page <= orders[:numero_paginas]
      orders[:pedidos].each do |order|
        process_order(order)
      end

      page += 1
      orders = Tiny::Orders.get_orders('preparando_envio', page)
    end
  end

  def process_order(order)
    return unless order.present?

    return if Attempt.find_by(tiny_order_id: order[:pedido][:id], status: :success)

    create_one_log_order(order)
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
      forma_envio: '',
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
    attempt.update(error: 'Dados do Cliente não disponíveis', status: :error) unless selected_order.present? && selected_order[:pedido].present? && selected_order[:pedido][:cliente].present?

    # Find client data on selected order hash
    return unless selected_order.present? && selected_order[:pedido].present? && selected_order[:pedido][:cliente].present?
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

    # assert email
    if client_data[:email].present?
      email = client_data[:email]
    else
      email = 'contato@chasebrasil.com'
    end

    # assert address
    if selected_order[:pedido][:endereco_entrega].present?
      endereco = selected_order[:pedido][:endereco_entrega][:endereco]
      numero = selected_order[:pedido][:endereco_entrega][:numero]
      complemento = selected_order[:pedido][:endereco_entrega][:complemento]
      bairro = selected_order[:pedido][:endereco_entrega][:bairro]
      cep = selected_order[:pedido][:endereco_entrega][:cep]
      cidade = selected_order[:pedido][:endereco_entrega][:cidade]
      fone = selected_order[:pedido][:endereco_entrega][:fone]
      uf = selected_order[:pedido][:endereco_entrega][:uf]
      cpf = selected_order[:pedido][:endereco_entrega][:cpf_cnpj]
    else
      endereco = client_data[:endereco]
      numero = client_data[:numero]
      complemento = client_data[:complemento]
      bairro = client_data[:bairro]
      cep = client_data[:cep]
      cidade = client_data[:cidade]
      fone = client_data[:fone]
      uf = client_data[:uf]
      cpf = client_data[:cpf_cnpj]
    end

    # assert sending way
    return attempt.update(error: 'Forma de Envio não localizada', status: :error) unless selected_order.dig(:pedido, :forma_frete).present?

    forma_envio_code = case selected_order[:pedido][:forma_frete]
                       when 'SEDEX'
                         '39888'
                       when 'PAC'
                         '39870'
                       when 'SEDEX HOJE'
                         '03662'
                       else
                         return attempt.update(error: 'Forma de Envio desconhecida', status: :error)
                       end

    # Setting founded valures
    begin
      params[:invoice]          << invoice[:numero]
      params[:numero_ecommerce] << ecommerce_number
      params[:data_pedido]      << selected_order[:pedido][:data_pedido]
      params[:valor]            << assert_value
      params[:nome]             << client_data[:nome]
      params[:endereco]         << endereco
      params[:numero]           << numero
      params[:complemento]      << complemento
      params[:bairro]           << bairro
      params[:cep]              << cep.gsub('.', '').gsub('-', '')
      params[:cidade]           << cidade
      params[:uf]               << uf
      params[:fone]             << fone
      params[:email]            << email
      params[:cpf_cnpj]         << cpf.gsub('.', '').gsub('-', '')
      params[:pedido_id]        << selected_order[:pedido][:id]
      params[:forma_envio]      << forma_envio_code

      # Form items array
      order_items = selected_order[:pedido][:itens]

      order_items.each do |oi|
        params[:itens] << { codigo: oi[:item][:codigo].upcase, quantidade: oi[:item][:quantidade].sub(/\.?0*\z/, '') }
      end

      attempt.update(id_nota_fiscal: selected_order[:pedido][:id_nota_fiscal].to_i, params:)

      verify_params(attempt, params)

    rescue StandardError => e
      attempt.update(error: e, status: :error)
    end

    # Create Order in Correios Log +
    Correios::Orders.create_orders(params, attempt) unless attempt.error.present?
  end

  def verify_params(attempt, params)
    required_params = [:data_pedido, :valor, :nome, :endereco, :bairro, :cep, :cidade, :numero, :uf, :email, :cpf_cnpj, :invoice, :forma_envio]

    missing_params = required_params.select { |param| params[param] == '' }

    return unless missing_params.any?
    error_message = "#{missing_params.join(', ')} não presente"
    attempt.update(error: error_message)
  end
end