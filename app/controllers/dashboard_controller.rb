class DashboardController < ApplicationController
  before_action :authenticate_user!

  # Actions exclusivas do painel "Correios B2B" (permissão dashboard_correios_b2b).
  B2B_ONLY_ACTIONS = %i[
    push_tracking_b2b run_push_tracking_b2b run_push_tracking_b2b_now
    send_xml_b2b run_send_xml_b2b run_send_xml_b2b_now
    invoice_emition_b2b run_invoice_emition_b2b run_invoice_emition_b2b_now
    order_correios_create_b2b order_correios_create_queue_b2b
    run_create_correios_b2b run_order_correios_create_b2b_now
    approve_order_b2b ignore_order_b2b
    order_correios_stock_errors_b2b order_correios_tracking_b2b api_correios_b2b
  ].freeze

  # Actions usadas pelas duas telas (buscas via AJAX) — liberadas para quem
  # tiver a permissão B2C ou a B2B.
  SHARED_CORREIOS_ACTIONS = %i[stockend tracking stuck_orders search_product].freeze

  # Janela de pedidos/tentativas exibidos nas telas Correios B2B.
  B2B_ORDERS_LOOKBACK = 8.weeks

  guard_screen :dashboard_correios, except: B2B_ONLY_ACTIONS + SHARED_CORREIOS_ACTIONS
  guard_screen :dashboard_correios_b2b, only: B2B_ONLY_ACTIONS
  before_action :authorize_correios_dashboard!, only: SHARED_CORREIOS_ACTIONS

  protect_from_forgery except: :modal_test

  require 'csv'

  def teste_embalagem; end

  def push_tracking
    tracked_ids = Attempt.where(kinds: :get_tracking, status: :success).pluck(:order_correios_id)

    latest_ids = Attempt.where(kinds: :send_xml, status: :success)
                        .where.not(order_correios_id: tracked_ids)
                        .select('MAX(id) AS id')
                        .group(:order_correios_id)

    @push_tracking = Attempt.where(id: latest_ids.map(&:id))
    @job_running = b2b_job_running?(:get_tracking)
  end

  def run_push_tracking
    if b2b_job_running?(:get_tracking)
      redirect_to push_tracking_dashboard_index_path, alert: 'Já existe uma execução dessa rotina em andamento!'
      return
    end

    marker = start_b2b_job_marker(:get_tracking)
    GetTrackingJob.perform_later('all', nil, marker.id)
    flash[:notice] = 'Rotina de solicitação de rastreio iniciada com sucesso!'
    redirect_to push_tracking_dashboard_index_path
  end

  def run_push_tracking_now
    queue_attempt = Attempt.find(params[:attempt_id])
    result = GetTrackingJob.new.get_one_tracking(queue_attempt)
    render json: attempt_result_json(result)
  rescue StandardError => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  def push_tracking_b2b
    tracked_ids = Attempt.where(kinds: :get_tracking_tiny2, status: :success).pluck(:order_correios_id)

    latest_ids = Attempt.where(kinds: :send_xml_tiny2, status: :success, is_transportadora: false)
                        .where.not(order_correios_id: tracked_ids)
                        .select('MAX(id) AS id')
                        .group(:order_correios_id)

    @push_tracking = Attempt.where(id: latest_ids.map(&:id))
    @order_types = B2bOrderType.for_orders(@push_tracking.map(&:tiny_order_id))
    @job_running = b2b_job_running?(:get_tracking_tiny2)
  end

  def run_push_tracking_b2b
    if b2b_job_running?(:get_tracking_tiny2)
      redirect_to push_tracking_b2b_dashboard_index_path, alert: 'Já existe uma execução dessa rotina em andamento!'
      return
    end

    marker = start_b2b_job_marker(:get_tracking_tiny2)
    GetTrackingJob2.perform_later('all', nil, marker.id)
    flash[:notice] = 'Rotina de solicitação de rastreio (B2B) iniciada com sucesso!'
    redirect_to push_tracking_b2b_dashboard_index_path
  end

  def run_push_tracking_b2b_now
    queue_attempt = Attempt.find(params[:attempt_id])
    result = GetTrackingJob2.new.get_one_tracking(queue_attempt)
    render json: attempt_result_json(result)
  rescue StandardError => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  def send_xml
    processed_ids = Attempt.where(kinds: :send_xml, status: 2, created_at: 30.days.ago..Time.current)
                           .pluck(:order_correios_id)

    invoiced_ids = Attempt.where(kinds: :emission_invoice, status: :success)
                          .pluck(:order_correios_id)

    @send_xml = Attempt.where(kinds: :create_correios_order, status: 2, created_at: 30.days.ago..Time.current)
                       .distinct(:order_correios_id)
                       .where.not(order_correios_id: processed_ids)
                       .where(order_correios_id: invoiced_ids)

    pending_order_ids = @send_xml.map(&:tiny_order_id).compact

    @last_errors = {}
    Attempt.where(kinds: :send_xml, status: [:fail, :error], tiny_order_id: pending_order_ids)
           .where.not(message: [nil, ''])
           .group_by(&:tiny_order_id).each do |order_id, attempts|
             last = attempts.max_by(&:updated_at)
             @last_errors[order_id.to_s] = {
               message: last.message,
               status: last.status,
               updated_at: last.updated_at
             }
           end

    @job_running = b2b_job_running?(:send_xml)
  end

  def run_send_xml
    if b2b_job_running?(:send_xml)
      redirect_to send_xml_dashboard_index_path, alert: 'Já existe uma execução dessa rotina em andamento!'
      return
    end

    marker = start_b2b_job_marker(:send_xml)
    SendXmlCorreiosLogJob.perform_later('all', nil, marker.id)
    flash[:notice] = 'Rotina de envio de XML aos Correios iniciada com sucesso!'
    redirect_to send_xml_dashboard_index_path
  end

  def run_send_xml_now
    queue_attempt = Attempt.find(params[:attempt_id])
    result = SendXmlCorreiosLogJob.new.send_one_xml(queue_attempt)
    render json: attempt_result_json(result)
  rescue StandardError => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  def send_xml_b2b
    processed_ids = Attempt.where(kinds: :send_xml_tiny2, status: 2, created_at: 30.days.ago..Time.current)
                           .pluck(:order_correios_id)

    invoiced_ids = Attempt.where(kinds: :emission_invoice_tiny2, status: :success)
                          .pluck(:order_correios_id)

    @send_xml = Attempt.where(kinds: :create_correios_order_tiny2, status: 2, created_at: 30.days.ago..Time.current)
                       .distinct(:order_correios_id)
                       .where.not(order_correios_id: processed_ids)
                       .where(order_correios_id: invoiced_ids)

    @filter_transportadora = params[:transportadora]
    @send_xml = @send_xml.where(is_transportadora: @filter_transportadora == 'outra') if @filter_transportadora.present?

    pending_order_ids = @send_xml.map(&:tiny_order_id).compact

    # Busca só a última tentativa com erro de cada pedido, sem as colunas de
    # texto pesadas (xml_nota/requisition) — carregar tudo estourava o timeout.
    latest_error_ids = Attempt.where(kinds: :send_xml_tiny2, status: [:fail, :error], tiny_order_id: pending_order_ids)
                              .where.not(message: [nil, ''])
                              .group(:tiny_order_id).maximum(:id).values

    @last_errors = Attempt.where(id: latest_error_ids)
                          .select(:id, :tiny_order_id, :message, :status, :updated_at)
                          .to_h do |last|
                            [last.tiny_order_id.to_s, { message: last.message, status: last.status, updated_at: last.updated_at }]
                          end

    @order_types = B2bOrderType.for_orders(pending_order_ids)
    @send_xml = filter_by_order_type(@send_xml, @order_types)
    @job_running = b2b_job_running?(:send_xml_tiny2)
  end

  def run_send_xml_b2b
    if b2b_job_running?(:send_xml_tiny2)
      redirect_to send_xml_b2b_dashboard_index_path, alert: 'Já existe uma execução dessa rotina em andamento!'
      return
    end

    marker = start_b2b_job_marker(:send_xml_tiny2)
    SendXmlCorreiosLogJob2.perform_later('all', nil, marker.id)
    flash[:notice] = 'Rotina de envio de XML aos Correios (B2B) iniciada com sucesso!'
    redirect_to send_xml_b2b_dashboard_index_path
  end

  def run_send_xml_b2b_now
    queue_attempt = Attempt.find(params[:attempt_id])
    result = SendXmlCorreiosLogJob2.new.send_one_xml(queue_attempt)
    render json: attempt_result_json(result)
  rescue StandardError => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  def invoice_emition
    successful_ids = Attempt.where(kinds: :emission_invoice, status: :success)
                            .pluck(:order_correios_id)
                            .compact
    @invoice_emition = Attempt.where(kinds: :create_correios_order, status: :success)
                              .where.not(order_correios_id: successful_ids)
                              .distinct(:order_correios_id)

    @job_running = b2b_job_running?(:emission_invoice)
    preload_address_corrections(@invoice_emition)
  end

  def run_invoice_emition
    if b2b_job_running?(:emission_invoice)
      redirect_to invoice_emition_dashboard_index_path, alert: 'Já existe uma execução dessa rotina em andamento!'
      return
    end

    marker = start_b2b_job_marker(:emission_invoice)
    InvoiceEmitionsJob.perform_later('all', nil, marker.id)
    flash[:notice] = 'Rotina de emissão de notas fiscais iniciada com sucesso!'
    redirect_to invoice_emition_dashboard_index_path
  end

  def run_invoice_emition_now
    queue_attempt = Attempt.find(params[:attempt_id])
    result = InvoiceEmitionsJob.new.one_emission(queue_attempt)
    render json: attempt_result_json(result)
  rescue StandardError => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  def invoice_emition_b2b
    successful_ids = Attempt.where(kinds: :emission_invoice_tiny2, status: :success)
                            .pluck(:order_correios_id)
                            .compact
    @invoice_emition = Attempt.where(kinds: :create_correios_order_tiny2, status: :success)
                              .where.not(order_correios_id: successful_ids)
                              .distinct(:order_correios_id)

    @filter_transportadora = params[:transportadora]
    @invoice_emition = @invoice_emition.where(is_transportadora: @filter_transportadora == 'outra') if @filter_transportadora.present?

    @job_running = b2b_job_running?(:emission_invoice_tiny2)
    preload_address_corrections(@invoice_emition)
    @order_types = B2bOrderType.for_orders(@invoice_emition.map(&:tiny_order_id))
  end

  def run_invoice_emition_b2b
    if b2b_job_running?(:emission_invoice_tiny2)
      redirect_to invoice_emition_b2b_dashboard_index_path, alert: 'Já existe uma execução dessa rotina em andamento!'
      return
    end

    marker = start_b2b_job_marker(:emission_invoice_tiny2)
    InvoiceEmitionsJob2.perform_later('all', nil, marker.id)
    flash[:notice] = 'Rotina de emissão de notas fiscais (B2B) iniciada com sucesso!'
    redirect_to invoice_emition_b2b_dashboard_index_path
  end

  def run_invoice_emition_b2b_now
    queue_attempt = Attempt.find(params[:attempt_id])
    result = InvoiceEmitionsJob2.new.one_emission(queue_attempt)
    render json: attempt_result_json(result)
  rescue StandardError => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  def stockend
    response = Correios::Orders.get_stock(params[:item_code], from_tiny2: params[:b2b] == '1')
    if response.code == 200
      @stock = response
    else
      @stock = nil
    end
    json_response(@stock)
  end

  def tracking
    response = Correios::Orders.get_tracking(params[:tracking_number], from_tiny2: params[:b2b] == '1')
    if response.code == 200
      @tracking = response['rastreio']
    else
      @tracking = nil
    end
    json_response(@tracking)
  end

  def stuck_orders
    summary = Correios::StuckOrders.summary_for_sku(params[:sku], from_tiny2: params[:b2b] == '1')
    json_response(summary)
  end

  def search_product
    query = params[:query].to_s.strip
    if query.blank?
      render json: { success: false, message: 'Query não fornecida' }
      return
    end

    products = Product.where('LOWER(sku) LIKE :q OR LOWER(shopify_product_name) LIKE :q', q: "%#{query.downcase}%").limit(10)

    render json: { success: true, products: products.map { |p| { sku: p.sku, name: p.shopify_product_name, image_url: image_url_for(p) } } }
  end

  def order_correios_create
    @orders_response = Tiny::Orders.get_all_orders_response('preparando_envio', ENV.fetch('TOKEN_TINY3_PRODUCTION'), 4.weeks.ago.strftime('%d/%m/%Y'))
    @orders = @orders_response&.dig('pedidos') || []
    @tiny_error = tiny_listing_error(@orders_response)

    successfully_processed_ids = Attempt.where(
      kinds: :create_correios_order,
      status: :success,
      created_at: 1.month.ago..Time.current
    ).pluck(:tiny_order_id).map(&:to_s)

    @pending_orders = @orders.reject do |order_data|
      order_id = order_data['pedido']['id'].to_s
      successfully_processed_ids.include?(order_id)
    end

    pending_order_ids = @pending_orders.map { |order_data| order_data['pedido']['id'].to_s }

    relevant_attempts = Attempt.where(
      kinds: :create_correios_order,
      tiny_order_id: pending_order_ids,
      created_at: 1.month.ago..Time.current
    ).order(:created_at)

    queue_attempts = []
    failed_attempts = []

    relevant_attempts.each do |attempt|
      case attempt.status
      when 'fail', 'processing'
        queue_attempts << attempt
      when 'error'
        failed_attempts << attempt if failed_attempts.size < 10
      end
    end

    @queue_positions = queue_attempts.each_with_index.to_h do |attempt, index|
      [
        attempt.tiny_order_id.to_s,
        {
          position: index + 1,
          status: attempt.status,
          created_at: attempt.created_at,
          updated_at: attempt.updated_at,
          message: attempt.message.presence || attempt.error
        }
      ]
    end

    @failed_attempts = failed_attempts.sort_by(&:updated_at).reverse

    grouped_status = relevant_attempts.group_by(&:status)
    @attempts_summary = {
      total: relevant_attempts.count,
      fail: grouped_status['fail']&.size || 0,
      error: grouped_status['error']&.size || 0,
      success: grouped_status['success']&.size || 0,
      processing: grouped_status['processing']&.size || 0
    }

    @last_errors = {}
    relevant_attempts
      .select { |a| (a.status.nil? || %w[fail error].include?(a.status)) && (a.message.present? || a.error.present?) }
      .group_by(&:tiny_order_id).each do |order_id, attempts|
        last = attempts.max_by(&:updated_at)
        @last_errors[order_id.to_s] = {
          message: last.message.presence || last.error,
          status: last.status || 'error',
          updated_at: last.updated_at
        }
      end

    @stats = {
      total_orders: @orders.count,
      pending_orders: @pending_orders.count,
      in_queue: queue_attempts.count,
      successful: successfully_processed_ids.count,
      failed: failed_attempts.count,
      pending: queue_attempts.count { |a| a.status == 'fail' },
      processing: queue_attempts.count { |a| a.status == 'processing' }
    }
  end

  def run_order_correios_create_now
    tiny_order_id = params[:attempt_id].to_s
    order = { pedido: { id: tiny_order_id } }
    result = CreateCorreiosLogOrdersJob.new.create_one_log_order(order)
    render json: attempt_result_json(result)
  rescue StandardError => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  def order_correios_create_b2b
    @orders_response = Tiny::Orders.get_all_orders_response('preparando_envio', ENV.fetch('TOKEN_TINY2_PRODUCTION'), B2B_ORDERS_LOOKBACK.ago.strftime('%d/%m/%Y'))
    orders = @orders_response&.dig('pedidos') || []

    successfully_processed_ids = Attempt.where(
      kinds: :create_correios_order_tiny2,
      status: :success,
      created_at: B2B_ORDERS_LOOKBACK.ago..Time.current
    ).pluck(:tiny_order_id).map(&:to_s)

    orders = orders.reject do |order_data|
      successfully_processed_ids.include?(order_data['pedido']['id'].to_s)
    end

    order_ids = orders.map { |order_data| order_data['pedido']['id'].to_s }
    @reviews = Tiny2OrderReview.where(tiny_order_id: order_ids).index_by(&:tiny_order_id)

    @review_filter = params[:review].presence || 'pending'

    @orders = orders.select do |order_data|
      review = @reviews[order_data['pedido']['id'].to_s]

      case @review_filter
      when 'approved' then review&.approved?
      when 'ignored' then review&.ignored?
      when 'all' then true
      else review.nil?
      end
    end

    @counts = {
      pending: orders.count { |order_data| @reviews[order_data['pedido']['id'].to_s].nil? },
      approved: orders.count { |order_data| @reviews[order_data['pedido']['id'].to_s]&.approved? },
      ignored: orders.count { |order_data| @reviews[order_data['pedido']['id'].to_s]&.ignored? }
    }

    @orders = @orders.paginate(page: params[:page], per_page: 20)
    load_b2b_order_types_from_tiny(@orders)

    @job_running = b2b_job_running?(:create_correios_order_tiny2)
  end

  def order_correios_create_queue_b2b
    @orders_response = Tiny::Orders.get_all_orders_response('preparando_envio', ENV.fetch('TOKEN_TINY2_PRODUCTION'), B2B_ORDERS_LOOKBACK.ago.strftime('%d/%m/%Y'))
    @orders = @orders_response&.dig('pedidos') || []

    successfully_processed_ids = Attempt.where(
      kinds: :create_correios_order_tiny2,
      status: :success,
      created_at: B2B_ORDERS_LOOKBACK.ago..Time.current
    ).pluck(:tiny_order_id).map(&:to_s)

    order_ids = @orders.map { |order_data| order_data['pedido']['id'].to_s }
    approved_ids = Tiny2OrderReview.where(tiny_order_id: order_ids, status: :approved).pluck(:tiny_order_id)

    @pending_orders = @orders.select do |order_data|
      order_id = order_data['pedido']['id'].to_s
      approved_ids.include?(order_id) && !successfully_processed_ids.include?(order_id)
    end

    pending_order_ids = @pending_orders.map { |order_data| order_data['pedido']['id'].to_s }
    load_b2b_order_types_from_tiny(@pending_orders)

    relevant_attempts = Attempt.where(
      kinds: :create_correios_order_tiny2,
      tiny_order_id: pending_order_ids,
      created_at: B2B_ORDERS_LOOKBACK.ago..Time.current
    ).order(:created_at)

    queue_attempts = []
    failed_attempts = []

    relevant_attempts.each do |attempt|
      case attempt.status
      when 'fail', 'processing'
        queue_attempts << attempt
      when 'error'
        failed_attempts << attempt if failed_attempts.size < 10
      end
    end

    @queue_positions = queue_attempts.each_with_index.to_h do |attempt, index|
      [
        attempt.tiny_order_id.to_s,
        {
          position: index + 1,
          status: attempt.status,
          created_at: attempt.created_at,
          updated_at: attempt.updated_at,
          message: attempt.message.presence || attempt.error
        }
      ]
    end

    @failed_attempts = failed_attempts.sort_by(&:updated_at).reverse

    grouped_status = relevant_attempts.group_by(&:status)
    @attempts_summary = {
      total: relevant_attempts.count,
      fail: grouped_status['fail']&.size || 0,
      error: grouped_status['error']&.size || 0,
      success: grouped_status['success']&.size || 0,
      processing: grouped_status['processing']&.size || 0
    }

    @last_errors = {}
    relevant_attempts
      .select { |a| (a.status.nil? || %w[fail error].include?(a.status)) && (a.message.present? || a.error.present?) }
      .group_by(&:tiny_order_id).each do |order_id, attempts|
        last = attempts.max_by(&:updated_at)
        @last_errors[order_id.to_s] = {
          message: last.message.presence || last.error,
          status: last.status || 'error',
          updated_at: last.updated_at
        }
      end

    @stats = {
      total_orders: @orders.count,
      pending_orders: @pending_orders.count,
      in_queue: queue_attempts.count,
      successful: successfully_processed_ids.count,
      failed: failed_attempts.count,
      pending: queue_attempts.count { |a| a.status == 'fail' },
      processing: queue_attempts.count { |a| a.status == 'processing' }
    }
  end

  def run_create_correios_b2b
    if b2b_job_running?(:create_correios_order_tiny2)
      redirect_to order_correios_create_b2b_dashboard_index_path(review: params[:review]), alert: 'Já existe uma execução dessa rotina em andamento!'
      return
    end

    marker = start_b2b_job_marker(:create_correios_order_tiny2)
    CreateCorreiosLogOrdersJob2.perform_later('all', nil, marker.id)
    flash[:notice] = 'Rotina de criação de pedidos no Correios (B2B) iniciada com sucesso!'
    redirect_to order_correios_create_b2b_dashboard_index_path(review: params[:review])
  end

  def run_order_correios_create_b2b_now
    tiny_order_id = params[:attempt_id].to_s
    order = { pedido: { id: tiny_order_id } }
    result = CreateCorreiosLogOrdersJob2.new.create_one_log_order(order)

    if result.nil?
      render json: { success: false, error: 'Pedido não aprovado para processamento.' }, status: :unprocessable_entity
      return
    end

    render json: attempt_result_json(result)
  rescue StandardError => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end

  def approve_order_b2b
    review = Tiny2OrderReview.find_or_initialize_by(tiny_order_id: params[:tiny_order_id].to_s)
    review.status = :approved
    review.save!

    redirect_to order_correios_create_b2b_dashboard_index_path(review: params[:review]),
                notice: "Pedido #{params[:tiny_order_id]} marcado para processamento."
  rescue StandardError => e
    redirect_to order_correios_create_b2b_dashboard_index_path(review: params[:review]),
                alert: "Erro ao marcar pedido: #{e.message}"
  end

  def ignore_order_b2b
    review = Tiny2OrderReview.find_or_initialize_by(tiny_order_id: params[:tiny_order_id].to_s)
    review.status = :ignored
    review.save!

    redirect_to order_correios_create_b2b_dashboard_index_path(review: params[:review]),
                notice: "Pedido #{params[:tiny_order_id]} ignorado."
  rescue StandardError => e
    redirect_to order_correios_create_b2b_dashboard_index_path(review: params[:review]),
                alert: "Erro ao ignorar pedido: #{e.message}"
  end

  def order_correios_stock_errors
    @orders_response = Tiny::Orders.get_orders_response(
      '',
      'preparando_envio',
      ENV.fetch('TOKEN_TINY3_PRODUCTION'),
      '',
      4.weeks.ago.strftime('%d/%m/%Y')
    )

    @orders = @orders_response&.dig('pedidos') || []

    successfully_processed_ids = Attempt.where(
      kinds: :create_correios_order,
      status: :success,
      created_at: 1.month.ago..Time.current
    ).pluck(:tiny_order_id).map(&:to_s)

    @pending_orders = @orders.reject do |order_data|
      order_id = order_data['pedido']['id'].to_s
      successfully_processed_ids.include?(order_id)
    end

    @orders_by_id = @pending_orders.index_by do |order_data|
      order_data['pedido']['id'].to_s
    end

    pending_order_ids = @pending_orders.map do |order_data|
      order_data['pedido']['id'].to_s
    end

    latest_attempt_by_order = latest_stock_error_attempts_by_order(:create_correios_order, pending_order_ids)

    unique_items_by_order_and_product = {}

    latest_attempt_by_order.each do |tiny_order_id, attempt|
      attempt_params = attempt.params.to_s
      order_data = @orders_by_id[tiny_order_id]&.dig('pedido')

      missing_product_codes = extract_missing_stock_product_codes(attempt.message)

      missing_product_codes.each do |product_code|
        quantity = extract_item_quantity_from_attempt_params(
          attempt_params,
          product_code
        )

        unique_key = "#{tiny_order_id}-#{product_code}"

        unique_items_by_order_and_product[unique_key] = {
          attempt_id: attempt.id,
          tiny_order_id: tiny_order_id,
          tiny_order_number: order_data&.dig('numero'),
          id_nota_fiscal: attempt.id_nota_fiscal.presence || extract_attempt_param(attempt_params, :invoice),
          numero_ecommerce: extract_attempt_param(attempt_params, :numero_ecommerce),
          customer_name: extract_attempt_param(attempt_params, :nome) || order_data&.dig('nome'),
          data_pedido: extract_attempt_param(attempt_params, :data_pedido) || order_data&.dig('data_pedido'),
          valor: extract_attempt_param(attempt_params, :valor) || order_data&.dig('valor'),
          product_code: product_code,
          quantity: quantity,
          status: attempt.status,
          message: attempt.message,
          created_at: attempt.created_at,
          updated_at: attempt.updated_at
        }
      end
    end

    @missing_stock_items = unique_items_by_order_and_product.values

    @missing_stock_summary = @missing_stock_items
      .group_by { |item| item[:product_code] }
      .map do |product_code, items|
        {
          product_code: product_code,
          orders_count: items.map { |item| item[:tiny_order_id] }.uniq.count,
          attempts_count: items.count,
          total_quantity: items.sum { |item| item[:quantity].to_s.tr(',', '.').to_f }
        }
      end
      .sort_by { |item| -item[:total_quantity] }

    @stats = {
      total_attempts: latest_attempt_by_order.size,
      total_items: @missing_stock_items.count,
      total_products: @missing_stock_summary.count,
      total_orders: @missing_stock_items.map { |item| item[:tiny_order_id] }.uniq.count
    }

    respond_to do |format|
      format.html

      format.csv do
        send_data(
          generate_order_correios_stock_errors_csv(@missing_stock_items),
          filename: "produtos_sem_estoque_correios_#{Time.current.strftime('%Y-%m-%d_%H-%M-%S')}.csv",
          type: 'text/csv; charset=utf-8',
          disposition: 'attachment'
        )
      end
    end
  end

  def order_correios_stock_errors_b2b
    @orders_response = Tiny::Orders.get_orders_response(
      '',
      'preparando_envio',
      ENV.fetch('TOKEN_TINY2_PRODUCTION'),
      '',
      B2B_ORDERS_LOOKBACK.ago.strftime('%d/%m/%Y')
    )

    @orders = @orders_response&.dig('pedidos') || []

    successfully_processed_ids = Attempt.where(
      kinds: :create_correios_order_tiny2,
      status: :success,
      created_at: B2B_ORDERS_LOOKBACK.ago..Time.current
    ).pluck(:tiny_order_id).map(&:to_s)

    @pending_orders = @orders.reject do |order_data|
      order_id = order_data['pedido']['id'].to_s
      successfully_processed_ids.include?(order_id)
    end

    @orders_by_id = @pending_orders.index_by do |order_data|
      order_data['pedido']['id'].to_s
    end

    pending_order_ids = @pending_orders.map do |order_data|
      order_data['pedido']['id'].to_s
    end

    latest_attempt_by_order = latest_stock_error_attempts_by_order(:create_correios_order_tiny2, pending_order_ids)

    unique_items_by_order_and_product = {}

    latest_attempt_by_order.each do |tiny_order_id, attempt|
      attempt_params = attempt.params.to_s
      order_data = @orders_by_id[tiny_order_id]&.dig('pedido')

      missing_product_codes = extract_missing_stock_product_codes(attempt.message)

      missing_product_codes.each do |product_code|
        quantity = extract_item_quantity_from_attempt_params(
          attempt_params,
          product_code
        )

        unique_key = "#{tiny_order_id}-#{product_code}"

        unique_items_by_order_and_product[unique_key] = {
          attempt_id: attempt.id,
          tiny_order_id: tiny_order_id,
          tiny_order_number: order_data&.dig('numero'),
          id_nota_fiscal: attempt.id_nota_fiscal.presence || extract_attempt_param(attempt_params, :invoice),
          numero_ecommerce: extract_attempt_param(attempt_params, :numero_ecommerce),
          customer_name: extract_attempt_param(attempt_params, :nome) || order_data&.dig('nome'),
          data_pedido: extract_attempt_param(attempt_params, :data_pedido) || order_data&.dig('data_pedido'),
          valor: extract_attempt_param(attempt_params, :valor) || order_data&.dig('valor'),
          product_code: product_code,
          quantity: quantity,
          status: attempt.status,
          message: attempt.message,
          created_at: attempt.created_at,
          updated_at: attempt.updated_at
        }
      end
    end

    @missing_stock_items = unique_items_by_order_and_product.values

    @missing_stock_summary = @missing_stock_items
      .group_by { |item| item[:product_code] }
      .map do |product_code, items|
        {
          product_code: product_code,
          orders_count: items.map { |item| item[:tiny_order_id] }.uniq.count,
          attempts_count: items.count,
          total_quantity: items.sum { |item| item[:quantity].to_s.tr(',', '.').to_f }
        }
      end
      .sort_by { |item| -item[:total_quantity] }

    @stats = {
      total_attempts: latest_attempt_by_order.size,
      total_items: @missing_stock_items.count,
      total_products: @missing_stock_summary.count,
      total_orders: @missing_stock_items.map { |item| item[:tiny_order_id] }.uniq.count
    }

    respond_to do |format|
      format.html { @order_types = B2bOrderType.for_orders(@missing_stock_items.map { |item| item[:tiny_order_id] }) }

      format.csv do
        send_data(
          generate_order_correios_stock_errors_csv(@missing_stock_items),
          filename: "produtos_sem_estoque_correios_b2b_#{Time.current.strftime('%Y-%m-%d_%H-%M-%S')}.csv",
          type: 'text/csv; charset=utf-8',
          disposition: 'attachment'
        )
      end
    end
  end

  def order_correios_tracking
    @filter_params = {
      status: params[:status],
      period: params[:period],
      order_id: params[:order_id]
    }

    prepare_tracking_data_optimized(@filter_params)
  end

  def order_correios_tracking_b2b
    @filter_params = {
      status: params[:status],
      period: params[:period],
      order_id: params[:order_id],
      transportadora: params[:transportadora]
    }

    prepare_tracking_data_optimized_b2b(@filter_params)
    @order_types = B2bOrderType.for_orders(@tracking_summary.keys)
  end

  def correios_pipeline
    @period = params[:period].presence || '30'

    respond_to do |format|
      format.html
      format.json { render json: pipeline_status_payload(@period) }
    end
  end

  def update_invoice_id
    tiny_order_id = params[:tiny_order_id]
    id_nota_fiscal = params[:id_nota_fiscal]

    if tiny_order_id.blank? || id_nota_fiscal.blank?
      redirect_to order_correios_tracking_dashboard_index_path, alert: 'Parâmetros obrigatórios não informados.'
      return
    end

    begin
      attempts = Attempt.where(tiny_order_id:, status: :success)

      if attempts.empty?
        redirect_to order_correios_tracking_dashboard_index_path, alert: "Nenhum attempt com status 'success' encontrado para o pedido #{tiny_order_id}."
        return
      end

      updated_count = attempts.update_all(id_nota_fiscal:)

      redirect_to order_correios_tracking_dashboard_index_path,
                  notice: "ID da nota fiscal atualizado com sucesso! #{updated_count} attempt(s) foram atualizados para o pedido #{tiny_order_id}."
    rescue StandardError => e
      Rails.logger.error "Erro ao atualizar ID da nota fiscal: #{e.message}"
      redirect_to order_correios_tracking_dashboard_index_path, 
                  alert: "Erro ao atualizar ID da nota fiscal: #{e.message}"
    end
  end

  def delete_order_from_queue
    tiny_order_id = params[:tiny_order_id]

    if tiny_order_id.blank?
      redirect_to order_correios_tracking_dashboard_index_path,
                  alert: 'O ID do pedido no Tiny é obrigatório.'
      return
    end

    begin
      attempts = Attempt.where(tiny_order_id: tiny_order_id)

      if attempts.empty?
        redirect_to order_correios_tracking_dashboard_index_path,
                    alert: "Nenhuma tentativa encontrada para o pedido #{tiny_order_id}."
        return
      end

      deleted_count = attempts.delete_all

      redirect_to order_correios_tracking_dashboard_index_path,
                  notice: "Pedido #{tiny_order_id} removido da fila com sucesso. #{deleted_count} tentativa(s) excluída(s)."
    rescue StandardError => e
      Rails.logger.error "Error deleting order from queue: #{e.message}"
      redirect_to order_correios_tracking_dashboard_index_path,
                  alert: "Erro ao remover o pedido da fila: #{e.message}"
    end
  end

  private

  # Filtro "Tipo do pedido" (abastecimento loja, transferência B2B -> B2C, B2B comum) das filas do Correios B2B.
  # O tipo é deduzido por pedido (B2bOrderType), então o filtro usa o resultado já calculado.
  def filter_by_order_type(scope, order_types)
    @order_type_counts = order_types.values.map(&:to_s).tally
    @filter_order_type = params[:order_type].presence_in(B2bOrderType::LABELS.keys.map(&:to_s))
    return scope unless @filter_order_type

    scope.where(tiny_order_id: order_types.select { |_, type| type.to_s == @filter_order_type }.keys)
  end

  def authorize_correios_dashboard!
    return if current_user&.can_access_screen?('dashboard_correios') ||
              current_user&.can_access_screen?('dashboard_correios_b2b')

    redirect_to root_path, alert: 'Acesso negado.'
  end

  def image_url_for(product)
    return product.image_url if product.image_url.present?

    Shopify::Products.update_product_with_shopify_id(product) if product.shopify_product_id.blank?
    return nil unless product.shopify_product_id.present?

    Shopify::Products.update_product_with_image_url(product)
    product.image_url
  end

  def b2b_job_running?(kind)
    Attempt.where(kinds: kind, status: :processing, tracking: 'manual_run_all').exists?
  end

  def start_b2b_job_marker(kind)
    Attempt.create!(
      kinds: kind,
      status: :processing,
      tracking: 'manual_run_all',
      message: "Execução manual iniciada por #{current_user.name}"
    )
  end

  # Pedido aguardando correção da nota no Tiny: o modal do "emitir agora" mostra o link da nota e o que digitar.
  def tiny_fix_json(attempt)
    correction = AddressCorrection.for(attempt.tiny_order_id)
    return unless correction&.awaiting_tiny_fix?

    { nota_url: view_context.nota_fiscal_edit_url(attempt.id_nota_fiscal), instructions: correction.fix_instructions, tiny_order_id: correction.tiny_order_id }
  end

  def attempt_result_json(attempt)
    {
      tiny_fix: tiny_fix_json(attempt),
      success: attempt.status == 'success',
      id: attempt.id,
      kinds: attempt.kinds,
      status: attempt.status,
      status_code: attempt.status_code,
      message: attempt.message,
      error: attempt.error,
      tracking: attempt.tracking,
      order_correios_id: attempt.order_correios_id,
      id_nota_fiscal: attempt.id_nota_fiscal,
      tiny_order_id: attempt.tiny_order_id,
      created_at: attempt.created_at&.strftime('%d/%m/%Y %H:%M:%S'),
      xml_nota: attempt.xml_nota,
      params: attempt.params,
      requisition: attempt.requisition
    }
  end

  def generate_order_correios_stock_errors_csv(items)
    csv_data = CSV.generate(
      col_sep: ';',
      force_quotes: true,
      encoding: 'UTF-8'
    ) do |csv|
      csv << [
        'Produto',
        'Quantidade necessária',
        'Número do pedido Tiny',
        'ID do pedido Tiny',
        'Nota fiscal Tiny',
        'Pedido ecommerce',
        'Cliente',
        'Data do pedido',
        'Valor',
        'Attempt',
        'Status',
        'Última atualização',
        'Mensagem'
      ]

      items.each do |item|
        csv << [
          sanitize_csv_value(item[:product_code]),
          format_csv_number(item[:quantity]),
          sanitize_csv_value(item[:tiny_order_number]),
          sanitize_csv_value(item[:tiny_order_id]),
          sanitize_csv_value(item[:id_nota_fiscal]),
          sanitize_csv_value(item[:numero_ecommerce]),
          sanitize_csv_value(item[:customer_name]),
          format_csv_date(item[:data_pedido]),
          format_csv_money(item[:valor]),
          sanitize_csv_value(item[:attempt_id]),
          sanitize_csv_value(item[:status]),
          format_csv_datetime(item[:updated_at]),
          sanitize_csv_value(item[:message])
        ]
      end
    end

    "\uFEFF#{csv_data}"
  end

  def sanitize_csv_value(value)
    text = value.to_s

    return text unless text.match?(/\A[=+\-@]/)

    "'#{text}"
  end

  def format_csv_number(value)
    return '' if value.blank?

    value.to_s.tr('.', ',')
  end

  def format_csv_money(value)
    return '' if value.blank?

    format('%.2f', value.to_f).tr('.', ',')
  end

  def format_csv_date(value)
    return '' if value.blank?

    value.respond_to?(:strftime) ? value.strftime('%d/%m/%Y') : value.to_s
  end

  def format_csv_datetime(value)
    return '' if value.blank?

    value.respond_to?(:strftime) ? value.strftime('%d/%m/%Y %H:%M') : value.to_s
  end

  CORREIOS_MISSING_STOCK_MESSAGE = 'Produto(s) informado(s) não existe(m) no estoque:'.freeze
  # Ex.: "Foi soliciatado 4 do item TAI-1546-P, mas o estoque e de apenas: 3."
  CORREIOS_INSUFFICIENT_STOCK_REGEX = /Foi solici\w*\s+[\d.,]+\s+do item\s+([\w\-.]+),\s*mas o estoque/i

  # Tentativa mais recente de cada pedido, considerando TODAS as falhas (não só
  # as de estoque) — só entra na lista se essa última tentativa for de estoque.
  # Assim, um pedido cujo erro mudou não fica preso a um erro de estoque antigo.
  def latest_stock_error_attempts_by_order(kind, tiny_order_ids)
    latest_ids = Attempt.where(
      kinds: kind,
      tiny_order_id: tiny_order_ids,
      created_at: 1.month.ago..Time.current
    ).group(:tiny_order_id).maximum(:id).values

    Attempt.where(id: latest_ids)
           .select { |attempt| extract_missing_stock_product_codes(attempt.message).any? }
           .index_by { |attempt| attempt.tiny_order_id.to_s }
  end

  def extract_missing_stock_product_codes(message)
    message = message.to_s

    if message.include?(CORREIOS_MISSING_STOCK_MESSAGE)
      message.split(CORREIOS_MISSING_STOCK_MESSAGE, 2)
             .last
             .to_s
             .split(/[,;\s]+/)
             .map { |code| code.gsub(/[^\w\-.]/, '') }
             .reject(&:blank?)
             .uniq
    else
      message.scan(CORREIOS_INSUFFICIENT_STOCK_REGEX).flatten.uniq
    end
  end

  def extract_attempt_param(attempt_params, key)
    attempt_params.to_s.match(/:#{Regexp.escape(key.to_s)}=>"([^"]*)"/)&.captures&.first
  end

  def extract_item_quantity_from_attempt_params(attempt_params, product_code)
    item_match = attempt_params.to_s.scan(/\{[^{}]*:codigo=>"#{Regexp.escape(product_code)}"[^{}]*\}/).first

    item_match&.match(/:quantidade=>"([^"]*)"/)&.captures&.first || '0'
  end

  def prepare_tracking_data_optimized(filters = {})
    base_conditions = []
    sql_params = {}

    if filters[:period].present?
      case filters[:period]
      when 'today'
        base_conditions << 'so.created_at >= :today_start'
        sql_params[:today_start] = Date.current.beginning_of_day
      when '7'
        base_conditions << 'so.created_at >= :week_start'
        sql_params[:week_start] = 7.days.ago
      when '30'
        base_conditions << 'so.created_at >= :month_start'
        sql_params[:month_start] = 30.days.ago
      when '90'
        base_conditions << 'so.created_at >= :quarter_start'
        sql_params[:quarter_start] = 90.days.ago
      end
    end

    if filters[:order_id].present?
      base_conditions << 'so.tiny_order_id = :order_id'
      sql_params[:order_id] = filters[:order_id]
    end

    # Não inclui "WHERE" aqui — usamos "WHERE 1=1" dentro das CTEs e da query principal
    conditions_sql = base_conditions.any? ? "AND #{base_conditions.join(' AND ')}" : ''

    sql = <<-SQL
      WITH successful_orders AS (
        SELECT tiny_order_id, order_correios_id, MAX(created_at) AS created_at
        FROM attempts
        WHERE kinds = 0 AND status = 2
        GROUP BY tiny_order_id, order_correios_id
      ),
      invoice_pending AS (
        SELECT so.tiny_order_id
        FROM successful_orders so
        WHERE 1=1
        #{conditions_sql}
        AND NOT EXISTS (
          SELECT 1 FROM attempts a
          WHERE a.order_correios_id = so.order_correios_id
            AND a.kinds = 2 AND a.status = 2
        )
      ),
      xml_pending AS (
        SELECT so.tiny_order_id
        FROM successful_orders so
        WHERE 1=1
        #{conditions_sql}
        AND EXISTS (
          SELECT 1 FROM attempts a
          WHERE a.order_correios_id = so.order_correios_id
            AND a.kinds = 2 AND a.status = 2
        )
        AND NOT EXISTS (
          SELECT 1 FROM attempts a
          WHERE a.order_correios_id = so.order_correios_id
            AND a.kinds = 1 AND a.status = 2
        )
      ),
      tracking_pending AS (
        SELECT so.tiny_order_id
        FROM successful_orders so
        WHERE 1=1
        #{conditions_sql}
        AND EXISTS (
          SELECT 1 FROM attempts a
          WHERE a.order_correios_id = so.order_correios_id
            AND a.kinds = 1 AND a.status = 2
        )
        AND NOT EXISTS (
          SELECT 1 FROM attempts a
          WHERE a.order_correios_id = so.order_correios_id
            AND a.kinds = 3 AND a.status = 2
        )
      )
      SELECT
        so.tiny_order_id,
        CASE
          WHEN ip.tiny_order_id IS NOT NULL THEN 'invoice_emition'
          WHEN xp.tiny_order_id IS NOT NULL THEN 'send_xml'
          WHEN tp.tiny_order_id IS NOT NULL THEN 'push_tracking'
          ELSE 'completed'
        END AS current_status
      FROM successful_orders so
      LEFT JOIN invoice_pending ip ON so.tiny_order_id = ip.tiny_order_id
      LEFT JOIN xml_pending xp ON so.tiny_order_id = xp.tiny_order_id
      LEFT JOIN tracking_pending tp ON so.tiny_order_id = tp.tiny_order_id
      WHERE 1=1
      #{conditions_sql}
      ORDER BY so.created_at DESC;
    SQL

    results = if sql_params.any?
      ActiveRecord::Base.connection.exec_query(
        ActiveRecord::Base.sanitize_sql_array([sql, sql_params])
      )
    else
      ActiveRecord::Base.connection.exec_query(sql)
    end

    @tracking_summary = {}
    invoice_count = 0
    xml_count = 0
    tracking_count = 0

    results.rows.each do |row|
      order_id = row[0].to_s
      status = row[1]

      next if filters[:status].present? && filters[:status] != status

      @tracking_summary[order_id] = {
        invoice_emition: status == 'invoice_emition',
        send_xml: status == 'send_xml',
        push_tracking: status == 'push_tracking'
      }

      case status
      when 'invoice_emition'
        invoice_count += 1
      when 'send_xml'
        xml_count += 1
      when 'push_tracking'
        tracking_count += 1
      end
    end

    @tracking_stats = {
      invoice_emition: invoice_count,
      send_xml: xml_count,
      push_tracking: tracking_count,
      total_tracking: @tracking_summary.count
    }

    # O nome do cliente vem do "params" gravado quando o pedido foi criado no
    # Correios (CreateCorreiosLogOrdersJob#create_one_log_order).
    client_names_by_tiny_id = Attempt.where(kinds: :create_correios_order, status: :success, tiny_order_id: @tracking_summary.keys)
                                      .where.not(params: [nil, ''])
                                      .order(created_at: :desc)
                                      .pluck(:tiny_order_id, :params)
                                      .each_with_object({}) do |(order_id, params), h|
                                        h[order_id.to_s] ||= params[/:nome\s*=>\s*"([^"]*)"/, 1]
                                      end

    @tracking_summary.each do |order_id, data|
      data[:client_name] = client_names_by_tiny_id[order_id]
    end
  end

  def prepare_tracking_data_optimized_b2b(filters = {})
    base_conditions = []
    sql_params = {}

    if filters[:period].present?
      case filters[:period]
      when 'today'
        base_conditions << 'so.created_at >= :today_start'
        sql_params[:today_start] = Date.current.beginning_of_day
      when '7'
        base_conditions << 'so.created_at >= :week_start'
        sql_params[:week_start] = 7.days.ago
      when '30'
        base_conditions << 'so.created_at >= :month_start'
        sql_params[:month_start] = 30.days.ago
      when '90'
        base_conditions << 'so.created_at >= :quarter_start'
        sql_params[:quarter_start] = 90.days.ago
      end
    end

    if filters[:order_id].present?
      base_conditions << 'so.tiny_order_id = :order_id'
      sql_params[:order_id] = filters[:order_id]
    end

    if filters[:transportadora].present?
      base_conditions << 'so.is_transportadora = :transportadora'
      sql_params[:transportadora] = filters[:transportadora] == 'outra' ? 1 : 0
    end

    # Não inclui "WHERE" aqui — usamos "WHERE 1=1" dentro das CTEs e da query principal
    conditions_sql = base_conditions.any? ? "AND #{base_conditions.join(' AND ')}" : ''

    create_kind = Attempt.kinds[:create_correios_order_tiny2]
    invoice_kind = Attempt.kinds[:emission_invoice_tiny2]
    xml_kind = Attempt.kinds[:send_xml_tiny2]
    tracking_kind = Attempt.kinds[:get_tracking_tiny2]
    success_status = Attempt.statuses[:success]

    sql = <<-SQL
      WITH successful_orders AS (
        SELECT tiny_order_id, order_correios_id, is_transportadora, MAX(created_at) AS created_at
        FROM attempts
        WHERE kinds = #{create_kind} AND status = #{success_status} AND tiny_order_id IS NOT NULL
        GROUP BY tiny_order_id, order_correios_id, is_transportadora
      )
      SELECT
        so.tiny_order_id,
        so.is_transportadora,
        EXISTS (
          SELECT 1 FROM attempts a
          WHERE a.order_correios_id = so.order_correios_id
            AND a.kinds = #{invoice_kind} AND a.status = #{success_status}
        ) AS invoice_done,
        EXISTS (
          SELECT 1 FROM attempts a
          WHERE a.order_correios_id = so.order_correios_id
            AND a.kinds = #{xml_kind} AND a.status = #{success_status}
        ) AS xml_done,
        EXISTS (
          SELECT 1 FROM attempts a
          WHERE a.order_correios_id = so.order_correios_id
            AND a.kinds = #{tracking_kind} AND a.status = #{success_status}
        ) AS tracking_done
      FROM successful_orders so
      WHERE 1=1
      #{conditions_sql}
      ORDER BY so.created_at DESC;
    SQL

    results = if sql_params.any?
      ActiveRecord::Base.connection.exec_query(
        ActiveRecord::Base.sanitize_sql_array([sql, sql_params])
      )
    else
      ActiveRecord::Base.connection.exec_query(sql)
    end

    boolean_type = ActiveModel::Type::Boolean.new

    @tracking_summary = {}
    invoice_count = 0
    xml_count = 0
    tracking_count = 0

    results.rows.each do |row|
      order_id = row[0].to_s
      is_transportadora = boolean_type.cast(row[1])
      invoice_done = boolean_type.cast(row[2])
      xml_done = boolean_type.cast(row[3])
      tracking_done = boolean_type.cast(row[4])

      # Cada etapa só pode estar concluída se as etapas anteriores do fluxo também estiverem
      # (Criação → Emissão de Nota → Envio XML → Rastreamento), senão fica "Na Fila".
      current_status =
        if !invoice_done
          'invoice_emition'
        elsif !xml_done
          'send_xml'
        elsif is_transportadora || tracking_done
          'completed'
        else
          'push_tracking'
        end

      next if filters[:status].present? && filters[:status] != current_status

      @tracking_summary[order_id] = {
        invoice_done: invoice_done,
        xml_done: xml_done,
        tracking_done: tracking_done,
        is_transportadora: is_transportadora,
        current_status: current_status
      }

      case current_status
      when 'invoice_emition'
        invoice_count += 1
      when 'send_xml'
        xml_count += 1
      when 'push_tracking'
        tracking_count += 1
      end
    end

    @tracking_stats = {
      invoice_emition: invoice_count,
      send_xml: xml_count,
      push_tracking: tracking_count,
      total_tracking: @tracking_summary.count
    }

    # O nome do cliente vem do "params" gravado quando o pedido foi criado no
    # Correios (CreateCorreiosLogOrdersJob2#create_one_log_order) — não existe
    # um B2bOrder correspondente pra esses pedidos, pois eles vêm direto do Tiny.
    client_names_by_tiny_id = Attempt.where(kinds: create_kind, status: success_status, tiny_order_id: @tracking_summary.keys)
                                      .where.not(params: [nil, ''])
                                      .order(created_at: :desc)
                                      .pluck(:tiny_order_id, :params)
                                      .each_with_object({}) do |(order_id, params), h|
                                        h[order_id.to_s] ||= params[/:nome\s*=>\s*"([^"]*)"/, 1]
                                      end

    @tracking_summary.each do |order_id, data|
      data[:client_name] = client_names_by_tiny_id[order_id]
    end
  end

  # Uma consulta só para as correções de endereço dos pedidos listados (evita uma por linha).
  # Tipo de cada pedido B2B da listagem do Tiny (o nome do cliente decide se vale buscar o pedido completo).
  def load_b2b_order_types_from_tiny(orders)
    pedidos = orders.map { |order_data| order_data['pedido'] }
    @order_types = B2bOrderType.for_orders(pedidos.map { |pedido| pedido['id'] },
                                           names: pedidos.to_h { |pedido| [pedido['id'].to_s, pedido['nome']] })
  end

  def preload_address_corrections(attempts)
    ids = attempts.map { |attempt| attempt.tiny_order_id.to_s }.reject(&:blank?).uniq
    @address_corrections = AddressCorrection.where(tiny_order_id: ids).index_by(&:tiny_order_id)
  end

  # Marca cada linha do relatório com o estado da correção de endereço do pedido, para a tela exibir o selo.
  def annotate_address_corrections(result)
    rows = Array(result[:attention])
    return result if rows.empty?

    corrections = AddressCorrection.where(tiny_order_id: rows.map { |row| row[:tiny_order_id].to_s }).index_by(&:tiny_order_id)
    annotated = rows.map do |row|
      correction = corrections[row[:tiny_order_id].to_s]
      state = correction && (correction.awaiting_tiny_fix? ? 'awaiting' : 'corrected')
      row.merge(address_correction: state)
    end
    result.merge(attention: annotated)
  end

  def pipeline_status_payload(period)
    raw = $redis.get(FetchCorreiosPipelineReportJob.result_key(period))

    if raw
      result = JSON.parse(raw, symbolize_names: true)
      return { status: 'error', error: result[:error] } if result[:error]

      return annotate_address_corrections(result).merge(status: 'done')
    end

    processing_key = FetchCorreiosPipelineReportJob.processing_key(period)
    acquired_lock = $redis.set(processing_key, '1', nx: true, ex: FetchCorreiosPipelineReportJob::PROCESSING_TTL)
    FetchCorreiosPipelineReportJob.perform_later(period) if acquired_lock

    { status: 'processing' }
  rescue Redis::BaseError => e
    { status: 'error', error: e.message }
  end

  def ranking_sellers
    orders_with_sellers = Order.where.not(tags: [nil, ''])
    sellers_stats = Hash.new do |hash, key|
      hash[key] = {
        total: 0,
        migrated: 0,
        not_migrated: 0,
        by_kind: Hash.new { |h, k| h[k] = { total: 0, migrated: 0 } },
        by_month: Hash.new { |h, k| h[k] = { total: 0, migrated: 0 } },
        by_weekday: Array.new(7, 0)
      }
    end

    orders_with_sellers.each do |order|
      seller_name = order.tags.strip
      sellers_stats[seller_name][:total] += 1

      if order.shopify_order_id.present?
        sellers_stats[seller_name][:migrated] += 1
      else
        sellers_stats[seller_name][:not_migrated] += 1
      end

      sellers_stats[seller_name][:by_kind][order.kinds][:total] += 1
      sellers_stats[seller_name][:by_kind][order.kinds][:migrated] += 1 if order.shopify_order_id.present?

      date = if order.tiny_creation_date.is_a?(String)
        Date.strptime(order.tiny_creation_date, '%d/%m/%Y')
      else
        order.tiny_creation_date.try(:to_date)
      end

      next unless date.present?

      month_key = date.strftime('%Y-%m')
      sellers_stats[seller_name][:by_month][month_key][:total] += 1
      sellers_stats[seller_name][:by_month][month_key][:migrated] += 1 if order.shopify_order_id.present?

      wday = date.wday
      sellers_stats[seller_name][:by_weekday][wday] += 1
    end

    sellers_stats.each do |seller, stats|
      stats[:migration_percentage] = stats[:total].positive? ? (stats[:migrated].to_f / stats[:total] * 100).round : 0

      stats[:by_kind].each_value do |kind_stats|
        kind_stats[:migration_percentage] = kind_stats[:total].positive? ? (kind_stats[:migrated].to_f / kind_stats[:total] * 100).round : 0
      end

      stats[:by_month].each_value do |month_stats|
        month_stats[:migration_percentage] = month_stats[:total].positive? ? (month_stats[:migrated].to_f / month_stats[:total] * 100).round : 0
      end

      months = stats[:by_month].keys.sort.last(6)
      if months.length >= 6
        recent_months = months.last(3)
        previous_months = months.first(3)
        recent_total = recent_months.sum { |m| stats[:by_month][m][:total] }
        previous_total = previous_months.sum { |m| stats[:by_month][m][:total] }
        stats[:trend] = if previous_total.positive?
          ((recent_total.to_f / previous_total) - 1) * 100
        else
          0
        end
      else
        stats[:trend] = 0
      end

      stats[:best_weekday] = stats[:by_weekday].index(stats[:by_weekday].max)
      active_days = stats[:by_month].sum { |_, month_stats| stats[:total].positive? ? 1 : 0 }
      stats[:daily_average] = active_days.positive? ? (stats[:total].to_f / active_days).round(1) : 0
    end

    @sellers_ranking = sellers_stats.sort_by { |_, stats| -stats[:total] }
    @total_orders = @sellers_ranking.sum { |_, stats| stats[:total] }
    @total_migrated = @sellers_ranking.sum { |_, stats| stats[:migrated] }
    @total_not_migrated = @sellers_ranking.sum { |_, stats| stats[:not_migrated] }
    @migration_percentage = @total_orders.positive? ? (@total_migrated.to_f / @total_orders * 100).round : 0

    @context_stats = {}
    ['rj', 'bh_shopping', 'lagoa_seca'].each do |kind|
      @context_stats[kind] = {
        total: 0,
        migrated: 0,
        not_migrated: 0,
        sellers: 0,
        migration_percentage: 0
      }
    end

    ['rj', 'bh_shopping', 'lagoa_seca'].each do |kind|
      @sellers_ranking.each do |_, stats|
        if stats[:by_kind][kind] && stats[:by_kind][kind][:total].positive?
          @context_stats[kind][:total] += stats[:by_kind][kind][:total]
          @context_stats[kind][:migrated] += stats[:by_kind][kind][:migrated]
          @context_stats[kind][:not_migrated] += stats[:by_kind][kind][:total] - stats[:by_kind][kind][:migrated]
          @context_stats[kind][:sellers] += 1
        end
      end

      @context_stats[kind][:migration_percentage] = @context_stats[kind][:total].positive? ? 
        (@context_stats[kind][:migrated].to_f / @context_stats[kind][:total] * 100).round : 0
    end

    prepare_chart_data
  end

  def prepare_chart_data
    top_sellers = @sellers_ranking.first(10)

    @top_sellers_chart_data = {
      labels: top_sellers.map { |seller, _| seller },
      series: [
        {
          name: 'Migrados',
          data: top_sellers.map { |_, stats| stats[:migrated] }
        },
        {
          name: 'Pendentes',
          data: top_sellers.map { |_, stats| stats[:not_migrated] }
        }
      ]
    }

    @sellers_distribution_data = {
      labels: top_sellers.map { |seller, _| seller },
      series: top_sellers.map { |_, stats| stats[:total] }
    }

    @sellers_efficiency_data = {
      labels: top_sellers.map { |seller, _| seller },
      series: [
        {
          name: 'Taxa de Migração',
          data: top_sellers.map { |_, stats| stats[:migration_percentage] }
        }
      ]
    }

    @context_distribution_data = {
      labels: ['Rio de Janeiro', 'BH Shopping', 'Lagoa Seca'],
      series: [
        {
          name: 'Migrados',
          data: ['rj', 'bh_shopping', 'lagoa_seca'].map { |kind| @context_stats[kind][:migrated] }
        },
        {
          name: 'Pendentes',
          data: ['rj', 'bh_shopping', 'lagoa_seca'].map { |kind| @context_stats[kind][:not_migrated] }
        }
      ]
    }

    weekdays = ['Domingo', 'Segunda', 'Terça', 'Quarta', 'Quinta', 'Sexta', 'Sábado']
    top5_sellers = @sellers_ranking.first(5)

    @weekday_distribution_data = {
      categories: weekdays,
      series: top5_sellers.map do |seller, stats|
        {
          name: seller,
          data: stats[:by_weekday]
        }
      end
    }

    all_months = @sellers_ranking.flat_map { |_, stats| stats[:by_month].keys }.uniq.sort.last(12)
    formatted_months = all_months.map do |month|
      year, month_num = month.split('-')
      Date.new(year.to_i, month_num.to_i, 1).strftime('%b/%Y')
    end

    @monthly_trend_data = {
      categories: formatted_months,
      series: top5_sellers.map do |seller, stats|
        {
          name: seller,
          data: all_months.map { |month| stats[:by_month][month] ? stats[:by_month][month][:total] : 0 }
        }
      end
    }
  end

  def api_correios; end

  def api_correios_b2b; end

  # Erro da listagem do Tiny para mostrar na tela (token inválido, limite de requisições...).
  # "A consulta não retornou registros" (código 20) é só fila vazia, não erro.
  def tiny_listing_error(retorno)
    return 'O Tiny não respondeu.' if retorno.blank?
    return if retorno['status'] == 'OK' || retorno['codigo_erro'].to_s == '20'

    Array(retorno['erros']).map { |e| e.is_a?(Hash) ? e['erro'] : e }.compact.join(', ').presence || "status #{retorno['status']}"
  end
end
