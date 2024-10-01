class MakeSpreadsheetJob < ApplicationJob
  queue_as :default

  def perform(origin, kind)
    case kind
    when 'product'
      generate_product_xlsx(origin)
    when 'order'
      generate_order_xlsx(origin)
    end
  end

  private

  def generate_product_xlsx(origin)
    workbook = RubyXL::Workbook.new
    tab = workbook.worksheets[0]
    tab.sheet_name = "Planilha estoque - (#{origin})"

    header = ['product_id',
              'title',
              'SKU',
              'regular_price',
              'price',
              'stock_quantity',
              'created_at',
              'updated_at',
              'managing_stock',
              'vendor',
              'permalink',
              'categories',
              'image',
              'brand',
              'options',
              'tags']

    header.each_with_index { |data, col| tab.add_cell(0, col, data) }

    Product.all.each_with_index do |product, row|
      tab.add_cell(row + 1, 0, product.id)
      tab.add_cell(row + 1, 1, product.shopify_product_name)
      tab.add_cell(row + 1, 2, product.sku)
      tab.add_cell(row + 1, 3, product.compare_at_price)
      tab.add_cell(row + 1, 4, product.price)
      tab.add_cell(row + 1, 5, calculate_stock_quantity(product, origin))
      tab.add_cell(row + 1, 6, product.created_at.strftime('%d/%m/%Y'))
      tab.add_cell(row + 1, 7, product.updated_at.strftime('%d/%m/%Y'))
      tab.add_cell(row + 1, 8, 'tiny')
      tab.add_cell(row + 1, 9, '')
      tab.add_cell(row + 1, 10, generate_permalink(product))
      tab.add_cell(row + 1, 11, fetch_categories)
      tab.add_cell(row + 1, 12, fetch_image)
      tab.add_cell(row + 1, 13, fetch_brand)
      tab.add_cell(row + 1, 14, generate_options(product))
      tab.add_cell(row + 1, 15, product.tags)
    end

    clear_folder_and_save_xlsx(workbook, origin, 'product')
  end

  def generate_order_xlsx(origin)
    workbook = RubyXL::Workbook.new
    tab = workbook.worksheets[0]
    tab.sheet_name = "Planilha Pedidos - (#{origin})"

    header = ['order_number', 'date', 'price', 'quantity', 'product_id', 'SKU', 'canceled']
    header.each_with_index { |data, col| tab.add_cell(0, col, data) }

    OrderItem.all.each_with_index do |order_item, row|
      order = order_item.order

      tab.add_cell(row + 1, 0, order.id)
      tab.add_cell(row + 1, 1, order_item.created_at.strftime('%d/%m/%Y'))
      tab.add_cell(row + 1, 2, order_item.price)
      tab.add_cell(row + 1, 3, order_item.quantity)
      tab.add_cell(row + 1, 4, order_item.product.present? ? order_item.product.shopify_product_id : '')
      tab.add_cell(row + 1, 5, order_item.sku)
      tab.add_cell(row + 1, 6, order_item.canceled? ? 'Sim' : 'Não')
    end

    clear_folder_and_save_xlsx(workbook, origin, 'order')
  end

  def clear_folder_and_save_xlsx(workbook, origin, type)
    folder_path = Rails.root.join('app', 'assets', 'planilhas', type, origin)

    FileUtils.mkdir_p(folder_path) unless File.directory?(folder_path)

    Dir.foreach(folder_path) do |file|
      file_path = File.join(folder_path, file)
      File.delete(file_path) if file != '.' && file != '..'
    end

    file_name = "planilha_#{type}_#{origin}.xlsx"

    file_path = File.join(folder_path, file_name)

    workbook.write(file_path)
    puts "Planilha salva em: #{file_path}"
  end

  def calculate_stock_quantity(product, origin)
    origin == 'lagoa_seca' ? product.stock_lagoa_seca.to_i : product.stock_bh_shopping.to_i
  end

  def generate_permalink(product)
    "https://example.com/products/#{product.id}"
  end

  def fetch_categories
    'Example Category'
  end

  def fetch_image
    'https://example.com/image.jpg'
  end

  def fetch_brand
    'Chase Brasil'
  end

  def generate_options(product)
    [product.option1, product.option2, product.option3].compact.join(', ')
  end
end
