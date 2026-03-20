class OrdersController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin!

  LOCATION_COLORS = [
    { bg: '0D6EFD', fg: 'FFFFFF' },
    { bg: '198754', fg: 'FFFFFF' },
    { bg: 'DC3545', fg: 'FFFFFF' },
    { bg: 'FFC107', fg: '000000' },
    { bg: '0DCAF0', fg: '000000' },
    { bg: '6F42C1', fg: 'FFFFFF' },
    { bg: 'FD7E14', fg: 'FFFFFF' },
    { bg: '20C997', fg: '000000' }
  ].freeze

  COUPON_PER_PAGE = 20

  def index
    @per_page     = (params[:per_page] || 15).to_i
    @current_page = (params[:page] || 1).to_i
    offset        = (@current_page - 1) * @per_page

    @locations       = Location.order(:name)
    @location_colors = build_location_colors(@locations)

    base_query    = build_query
    @orders       = base_query.limit(@per_page).offset(offset)
    @total_orders = base_query.count
    @total_pages  = (@total_orders.to_f / @per_page).ceil
  end

  def export
    @locations       = Location.order(:name)
    @location_colors = build_location_colors(@locations)
    @orders          = build_query

    location_name = if params[:location_id].present?
                      @locations.find { |l| l.id.to_s == params[:location_id] }&.name || "todos"
                    else
                      'todos'
                    end

    filename  = "pedidos_#{location_name.parameterize}_#{Date.today.strftime('%d-%m-%Y')}.xlsx"
    file_path = Rails.root.join('tmp', "orders_export_#{SecureRandom.hex(4)}.xlsx")

    workbook  = RubyXL::Workbook.new
    worksheet = workbook[0]
    worksheet.sheet_name = location_name.truncate(31)

    header_bg  = '1A73E8'
    header_fg  = 'FFFFFF'
    alt_row_bg = 'F0F5FF'

    headers = ['# Pedido Shopify', 'Nome do Cliente', 'Email', 'Telefone', 'Localização', 'Data Shopify', 'Criado em']
    headers.each_with_index do |h, col|
      cell = worksheet.add_cell(0, col, h)
      cell.change_font_bold(true)
      cell.change_font_color(header_fg)
      cell.change_fill(header_bg)
      cell.change_horizontal_alignment('center')
    end

    [22, 28, 32, 18, 24, 22, 22].each_with_index do |w, i|
      worksheet.change_column_width(i, w)
    end

    @orders.each_with_index do |order, i|
      row_num  = i + 1
      row_bg   = i.odd? ? alt_row_bg : 'FFFFFF'
      loc      = order.location
      loc_color = loc ? LOCATION_COLORS[@locations.index(loc) % LOCATION_COLORS.size] : nil

      row_data = [
        order.shopify_order_id.to_s,
        [order.customer&.first_name, order.customer&.last_name].compact.join(' '),
        order.customer&.email.to_s,
        order.customer&.phone.to_s,
        loc&.name || 'Sem location',
        order.shopify_creation_date&.strftime('%d/%m/%Y %H:%M') || '',
        order.created_at.strftime('%d/%m/%Y %H:%M')
      ]

      row_data.each_with_index do |value, col|
        cell = worksheet.add_cell(row_num, col, value)
        cell.change_fill(row_bg)

        if col == 4 && loc_color
          cell.change_fill(loc_color[:bg])
          cell.change_font_color(loc_color[:fg])
          cell.change_font_bold(true)
        end

        cell.change_horizontal_alignment(col == 0 ? 'center' : 'left')
      end
    end

    footer_cell = worksheet.add_cell(@orders.size + 2, 0, "Total de pedidos: #{@orders.size}")
    footer_cell.change_font_bold(true)
    footer_cell.change_font_color(header_bg)

    workbook.write(file_path.to_s)

    send_file file_path,
              filename: filename,
              type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
              disposition: 'attachment'
  end

  def coupon_usage
    base_scope = Order.where.not(discount_codes: nil).where.not(discount_codes: [])

    if params[:period].present?
      base_scope = base_scope.where('orders.created_at >= ?', params[:period].to_i.days.ago.beginning_of_day)
    end

    base_scope = base_scope.where('orders.created_at >= ?', Date.parse(params[:date_from]).beginning_of_day) if params[:date_from].present?
    base_scope = base_scope.where('orders.created_at <= ?', Date.parse(params[:date_to]).end_of_day) if params[:date_to].present?

    if params[:coupon_search].present?
      @search_term = params[:coupon_search].strip.upcase
    end

    coupon_counts = Hash.new(0)

    base_scope.each do |order|
      Array(order.discount_codes).each do |code|
        next if code.blank?

        normalized = code.to_s.upcase.strip

        # 🔥 REGRA 1: precisa conter "10"
        next unless normalized.include?("10")

        # ❌ REMOÇÕES
        next if normalized == "FRETE GRÁTIS"
        next if normalized == "TROCA55110JKQ"
        next if normalized == "MTZLQ97UREB7"

        # ⚠️ DANDYNHA10 (somente exato)
        if normalized.include?("DANDYNHA10") && normalized != "DANDYNHA10"
          next
        end

        coupon_counts[normalized] += 1
      end
    end

    # 🔎 filtro de busca
    if @search_term.present?
      coupon_counts = coupon_counts.select { |code, _| code.include?(@search_term) }
    end

    # 🚀 ORDENAÇÃO (DEFAULT = MAIS USADOS)
    if params[:sort] == "alphabetical"
      all_stats = coupon_counts.sort_by { |code, _| code }
    else
      # 🔥 padrão agora é por uso DESC
      all_stats = coupon_counts.sort_by { |_, count| -count }
    end

    @total_unique_coupons = all_stats.size
    @total_with_coupon    = base_scope.count
    @total_orders_global  = Order.count
    @top_coupon           = all_stats.first

    # 💰 revenue
    coupon_revenue = Hash.new(0.0)
    base_scope.pluck(:discount_codes, :current_total_price).each do |codes, price|
      Array(codes).each do |code|
        next if code.blank?

        normalized = code.to_s.upcase.strip

        next unless normalized.include?("10")
        next if normalized == "FRETE GRÁTIS"
        next if normalized == "TROCA55110JKQ"
        next if normalized == "MTZLQ97UREB7"

        if normalized.include?("DANDYNHA10") && normalized != "DANDYNHA10"
          next
        end

        coupon_revenue[normalized] += price.to_f
      end
    end

    @coupon_revenue = coupon_revenue

    @current_page  = (params[:page] || 1).to_i
    @per_page      = COUPON_PER_PAGE
    @total_pages   = (all_stats.size.to_f / @per_page).ceil
    @current_page  = [[@current_page, 1].max, [@total_pages, 1].max].min

    offset        = (@current_page - 1) * @per_page
    @coupon_stats = all_stats[offset, @per_page] || []

    if request.format.xlsx? || params[:format] == "xlsx"
      send_coupon_usage_xlsx(all_stats)
      return
    end
  end

  private

  def send_coupon_usage_xlsx(all_stats)
    require "rubyxl"
    require "rubyxl/convenience_methods"

    filename  = "uso_cupons_#{Date.today.strftime('%d-%m-%Y')}.xlsx"
    file_path = Rails.root.join("tmp", "coupon_usage_#{SecureRandom.hex(4)}.xlsx")

    workbook  = RubyXL::Workbook.new
    ws        = workbook[0]
    ws.sheet_name = "Uso de Cupons"

    headers = ["#", "Código do Cupom", "Nº de Usos"]

    headers.each_with_index do |h, col|
      ws.add_cell(0, col, h)
    end

    all_stats.each_with_index do |(code, count), i|
      ws.add_cell(i + 1, 0, i + 1)
      ws.add_cell(i + 1, 1, code)
      ws.add_cell(i + 1, 2, count)
    end

    workbook.write(file_path.to_s)

    send_file file_path,
              filename: filename,
              type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
              disposition: "attachment"
  end

  def build_query
    query = Order.includes(:customer, :location).order(created_at: :desc)

    if params[:search].present?
      term  = "%#{params[:search]}%"
      query = query.joins(:customer).where(
        "orders.shopify_order_id LIKE ? OR customers.email LIKE ? OR customers.first_name LIKE ? OR customers.last_name LIKE ?",
        term, term, term, term
      )
    end

    query = query.where(location_id: params[:location_id]) if params[:location_id].present?

    if params[:period].present?
      query = query.where("orders.created_at >= ?", params[:period].to_i.days.ago.beginning_of_day)
    end

    if params[:date_from].present?
      query = query.where("orders.created_at >= ?", Date.parse(params[:date_from]).beginning_of_day)
    end

    if params[:date_to].present?
      query = query.where("orders.created_at <= ?", Date.parse(params[:date_to]).end_of_day)
    end

    query
  end

  def build_location_colors(locations)
    locations.each_with_index.to_h { |loc, i| [loc.id, LOCATION_COLORS[i % LOCATION_COLORS.size]] }
  end

  def require_admin!
    redirect_to root_path, alert: "Acesso restrito a administradores." unless current_user&.admin? || current_user&.profiles&.any?(&:marketing_profile?)
  end
end