class OrdersController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin!

  LOCATION_COLORS = [
    { bg: "0D6EFD", fg: "FFFFFF" },
    { bg: "198754", fg: "FFFFFF" },
    { bg: "DC3545", fg: "FFFFFF" },
    { bg: "FFC107", fg: "000000" },
    { bg: "0DCAF0", fg: "000000" },
    { bg: "6F42C1", fg: "FFFFFF" },
    { bg: "FD7E14", fg: "FFFFFF" },
    { bg: "20C997", fg: "000000" },
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
                      "todos"
                    end

    filename  = "pedidos_#{location_name.parameterize}_#{Date.today.strftime('%d-%m-%Y')}.xlsx"
    file_path = Rails.root.join("tmp", "orders_export_#{SecureRandom.hex(4)}.xlsx")

    workbook  = RubyXL::Workbook.new
    worksheet = workbook[0]
    worksheet.sheet_name = location_name.truncate(31)

    header_bg  = "1A73E8"
    header_fg  = "FFFFFF"
    alt_row_bg = "F0F5FF"

    headers = ["# Pedido Shopify", "Nome do Cliente", "Email", "Telefone", "Localização", "Data Shopify", "Criado em"]
    headers.each_with_index do |h, col|
      cell = worksheet.add_cell(0, col, h)
      cell.change_font_bold(true)
      cell.change_font_color(header_fg)
      cell.change_fill(header_bg)
      cell.change_horizontal_alignment("center")
    end

    [22, 28, 32, 18, 24, 22, 22].each_with_index do |w, i|
      worksheet.change_column_width(i, w)
    end

    @orders.each_with_index do |order, i|
      row_num  = i + 1
      row_bg   = i.odd? ? alt_row_bg : "FFFFFF"
      loc      = order.location
      loc_color = loc ? LOCATION_COLORS[@locations.index(loc) % LOCATION_COLORS.size] : nil

      row_data = [
        order.shopify_order_id.to_s,
        [order.customer&.first_name, order.customer&.last_name].compact.join(" "),
        order.customer&.email.to_s,
        order.customer&.phone.to_s,
        loc&.name || "Sem location",
        order.shopify_creation_date&.strftime("%d/%m/%Y %H:%M") || "",
        order.created_at.strftime("%d/%m/%Y %H:%M")
      ]

      row_data.each_with_index do |value, col|
        cell = worksheet.add_cell(row_num, col, value)
        cell.change_fill(row_bg)
        if col == 4 && loc_color
          cell.change_fill(loc_color[:bg])
          cell.change_font_color(loc_color[:fg])
          cell.change_font_bold(true)
        end
        cell.change_horizontal_alignment(col == 0 ? "center" : "left")
      end
    end

    footer_cell = worksheet.add_cell(@orders.size + 2, 0, "Total de pedidos: #{@orders.size}")
    footer_cell.change_font_bold(true)
    footer_cell.change_font_color(header_bg)

    workbook.write(file_path.to_s)

    send_file file_path,
              filename:    filename,
              type:        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
              disposition: "attachment"
  end

  # GET  /orders/coupon_usage          — tela HTML
  # GET  /orders/coupon_usage.xlsx     — exportação para planilha
  def coupon_usage
    # Monta a query base respeitando filtros de data
    base_scope = Order.where.not(discount_codes: nil).where.not(discount_codes: [])

    # Filtro de período rápido (30 / 60 / 90 dias)
    if params[:period].present?
      days       = params[:period].to_i
      base_scope = base_scope.where("orders.created_at >= ?", days.days.ago.beginning_of_day)
    end

    # Filtro de intervalo customizado
    if params[:date_from].present?
      base_scope = base_scope.where("orders.created_at >= ?", Date.parse(params[:date_from]).beginning_of_day)
    end

    if params[:date_to].present?
      base_scope = base_scope.where("orders.created_at <= ?", Date.parse(params[:date_to]).end_of_day)
    end

    # Filtro por código digitado
    if params[:coupon_search].present?
      term       = params[:coupon_search].strip.upcase
      # discount_codes é um array serializado; filtra em Ruby após carregar
      @search_term = term
    end

    # Conta usos por cupom
    coupon_counts = Hash.new(0)
    base_scope.each do |order|
      Array(order.discount_codes).each do |code|
        next if code.blank?
        coupon_counts[code.to_s.upcase.strip] += 1
      end
    end

    # Aplica filtro de busca por nome de cupom
    if @search_term.present?
      coupon_counts = coupon_counts.select { |code, _| code.include?(@search_term) }
    end

    all_stats = coupon_counts.sort_by { |_, count| -count }

    # Totais gerais (sem paginação) para os cards de resumo
    @total_unique_coupons = all_stats.size
    @total_with_coupon    = base_scope.count
    @total_orders_global  = Order.count
    @top_coupon           = all_stats.first

    # Receita líquida (current_total_price) agrupada por cupom
    # Precisamos saber qual pedido tem qual cupom; como discount_codes é array serializado,
    # iteramos igual ao contador de usos, mas somando o valor.
    coupon_revenue = Hash.new(0.0)
    base_scope.pluck(:discount_codes, :current_total_price).each do |codes, price|
      Array(codes).each do |code|
        next if code.blank?
        coupon_revenue[code.to_s.upcase.strip] += price.to_f
      end
    end
    @coupon_revenue = coupon_revenue

    # Paginação
    @current_page  = (params[:page] || 1).to_i
    @per_page      = COUPON_PER_PAGE
    @total_pages   = (all_stats.size.to_f / @per_page).ceil
    @current_page  = [[@current_page, 1].max, [@total_pages, 1].max].min

    offset         = (@current_page - 1) * @per_page
    @coupon_stats  = all_stats[offset, @per_page] || []

    # Exportação XLSX
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

    header_bg = "1A73E8"
    header_fg = "FFFFFF"
    alt_bg    = "EEF4FF"

    headers = ["#", "Código do Cupom", "Nº de Usos", "% dos Pedidos com Cupom", "% do Total de Pedidos"]

    # Escreve linha de cabeçalho
    headers.each_with_index do |h, col|
      ws.add_cell(0, col, h)
    end

    # Aplica estilos no cabeçalho após gravar todos os valores
    headers.each_with_index do |_, col|
      cell = ws[0][col]
      next unless cell
      cell.change_font_bold(true)
      cell.change_font_color(header_fg)
      cell.change_fill(header_bg)
      cell.change_horizontal_alignment("center")
    end

    [8, 30, 16, 28, 28].each_with_index { |w, i| ws.change_column_width(i, w) }

    total_with_coupon = all_stats.sum { |_, c| c }
    total_orders      = Order.count

    all_stats.each_with_index do |(code, count), i|
      row_num    = i + 1
      row_bg     = i.odd? ? alt_bg : "FFFFFF"
      share_pct  = total_with_coupon > 0 ? ((count.to_f / total_with_coupon) * 100).round(2) : 0
      global_pct = total_orders      > 0 ? ((count.to_f / total_orders)      * 100).round(2) : 0

      values = [(i + 1).to_s, code.to_s, count.to_s, "#{share_pct}%", "#{global_pct}%"]

      # Grava valores
      values.each_with_index do |val, col|
        ws.add_cell(row_num, col, val)
      end

      # Aplica estilos após gravar
      values.each_with_index do |_, col|
        cell = ws[row_num][col]
        next unless cell
        cell.change_fill(row_bg)
        cell.change_horizontal_alignment(col == 0 ? "center" : "left")
      end
    end

    # Rodapé
    footer_row = all_stats.size + 2
    ws.add_cell(footer_row, 0, "Total de cupons únicos: #{all_stats.size}")
    ws[footer_row][0]&.change_font_bold(true)

    workbook.write(file_path.to_s)

    send_file file_path,
              filename:    filename,
              type:        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
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
