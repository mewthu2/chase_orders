require 'csv'

class PlannerOrdersController < ApplicationController
  before_action :authenticate_user!
  before_action :set_planner_order, only: [:show, :edit, :update, :transmit, :export_xlsx]

  def index
    @planner_orders = filter_planner_orders
  end

  def new
    @planner_order = PlannerOrder.new
  end

  def create
    @planner_order = PlannerOrder.new
    @planner_order.reference = generate_reference
    @planner_order.status = :draft
    @planner_order.user = current_user

    if params[:csv_file].present?
      begin
        filename = params[:csv_file].original_filename
        @planner_order.csv_filename = filename
        @planner_order.order_number = extract_order_number(filename)

        process_csv(params[:csv_file])
        @planner_order.status = :saved

        if @planner_order.save
          flash[:notice] = 'Pedido salvo com sucesso!'
          redirect_to planner_order_path(@planner_order)
        else
          flash.now[:alert] = 'Erro ao salvar pedido'
          render :new, status: :unprocessable_entity
        end
      rescue StandardError => e
        flash.now[:alert] = "Erro ao processar planilha: #{e.message}"
        @planner_order = PlannerOrder.new
        render :new, status: :unprocessable_entity
      end
    else
      flash.now[:alert] = 'Por favor, selecione uma planilha CSV'
      render :new, status: :unprocessable_entity
    end
  end

  def show
    @planner_order_items = @planner_order.planner_order_items.order(:name)
    @total_items = @planner_order_items.sum(:quantity)
  end

  def edit
  end

  def update
    if @planner_order.update(planner_order_params)
      flash[:notice] = 'Marcadores atualizados com sucesso!'
      redirect_to planner_order_path(@planner_order)
    else
      flash.now[:alert] = 'Erro ao atualizar marcadores'
      render :edit, status: :unprocessable_entity
    end
  end

  def transmit
    unless @planner_order.saved? || @planner_order.error? || (@planner_order.transmitted? && @planner_order.tiny_note_number.blank?)
      flash[:alert] = 'Este pedido não pode ser retransmitido'
      redirect_to planner_order_path(@planner_order)
      return
    end

    begin
      CreateNoteTinyJob.perform_later(@planner_order.id)
      @planner_order.update(status: :transmitted)
      flash[:notice] = 'Pedido enviado para transmissão ao Tiny com sucesso!'
      redirect_to planner_order_path(@planner_order)
    rescue StandardError => e
      @planner_order.update(status: :error, error_message: e.message)
      flash[:alert] = "Erro ao transmitir pedido: #{e.message}"
      redirect_to planner_order_path(@planner_order)
    end
  end

  def export_xlsx
    workbook  = RubyXL::Workbook.new
    worksheet = workbook[0]

    worksheet.add_cell(0, 0, 'Nome')
    worksheet.add_cell(0, 1, 'SKU')
    worksheet.add_cell(0, 2, 'Quantidade')

    row = 1
    items = @planner_order.planner_order_items.order(:name)

    items.each do |item|
      worksheet.add_cell(row, 0, item.name)
      worksheet.add_cell(row, 1, item.sku)
      worksheet.add_cell(row, 2, item.quantity)
      row += 1
    end

    total_quantity = items.sum(&:quantity)
    worksheet.add_cell(row, 1, 'TOTAL')
    worksheet.add_cell(row, 2, total_quantity)

    file_path = Rails.root.join('tmp', "planner_order_#{SecureRandom.hex(4)}.xlsx")

    workbook.write(file_path.to_s)

    send_file file_path,
              filename: "correios_#{@planner_order.reference}_#{Time.current.strftime('%Y%m%d')}.xlsx",
              type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
              disposition: 'attachment'
  end

  private

  def set_planner_order
    @planner_order = PlannerOrder.find(params[:id])
  end

  def filter_planner_orders
    orders = PlannerOrder.all

    if params[:search].present?
      search_term = "%#{params[:search]}%"
      orders = orders.where('reference ILIKE ? OR id::text LIKE ?', search_term, search_term)
    end

    orders = orders.where(status: params[:status]) if params[:status].present?

    if params[:sort].present?
      direction = params[:direction] == 'asc' ? 'ASC' : 'DESC'
      case params[:sort]
      when 'reference'
        orders = orders.order("reference #{direction}")
      when 'created_at'
        orders = orders.order("created_at #{direction}")
      when 'status'
        orders = orders.order("status #{direction}")
      end
    else
      orders = orders.order(created_at: :desc)
    end

    orders
  end

  def process_csv(file)
    csv_content = file.read.force_encoding('UTF-8')
    csv = CSV.parse(csv_content, headers: true)

    csv.each do |row|
      name = row['Name']
      sku = row['SKU']
      quantity = row['Ordered'].to_i

      next if name.blank? || sku.blank? || quantity <= 0

      @planner_order.planner_order_items.build(
        name:,
        sku:,
        quantity:
      )
    end

    raise 'Nenhum produto válido encontrado na planilha' if @planner_order.planner_order_items.empty?
  end

  def generate_reference
    date_prefix = Time.current.strftime('%Y%m%d')
    random_suffix = SecureRandom.hex(2).upcase
    "PO-#{date_prefix}-#{random_suffix}"
  end

  def extract_order_number(filename)
    match = filename.match(/TO-(\d+)/i)
    match ? match[1] : nil
  end

  def planner_order_params
    params.require(:planner_order).permit(:tags)
  end
end
