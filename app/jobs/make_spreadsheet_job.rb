class MakeSpreadsheetJob < ApplicationJob
  queue_as :default

  require 'csv'

  def perform(origin, kind)
    case kind
    when 'product'
      generate_product_csv(origin)
    when 'order'
      generate_order_csv(origin)
    end
  end

  private

  def generate_product_csv(origin)
    folder_path = Rails.root.join('app', 'assets', 'planilhas', 'product', origin)
    FileUtils.mkdir_p(folder_path) unless File.directory?(folder_path)

    Dir.foreach(folder_path) do |file|
      file_path = File.join(folder_path, file)
      File.delete(file_path) if file != '.' && file != '..'
    end

    csv_file_name = "planilha_product_#{origin}.csv"
    csv_file_path = File.join(folder_path, csv_file_name)

    CSV.open(csv_file_path, 'w') do |csv|
      header = ['product_id', 'title', 'SKU', 'price', 'created_at', 'stock_quantity']
      csv << header

      Product.all.each do |product|
        csv << [
          product.shopify_product_id,
          product.shopify_product_name,
          product.sku,
          product.price,
          product.created_at&.strftime('%d/%m/%Y'),
          calculate_stock_quantity(product, origin)
        ]
      end
    end

    puts "Arquivo CSV de produtos salvo em: #{csv_file_path}"
  end

  def generate_order_csv(origin)
    folder_path = Rails.root.join('app', 'assets', 'planilhas', 'order', origin)
    FileUtils.mkdir_p(folder_path) unless File.directory?(folder_path)

    Dir.foreach(folder_path) do |file|
      file_path = File.join(folder_path, file)
      File.delete(file_path) if file != '.' && file != '..'
    end

    csv_file_name = "planilha_order_#{origin}.csv"
    csv_file_path = File.join(folder_path, csv_file_name)

    CSV.open(csv_file_path, 'w') do |csv|
      header = ['order_number', 'date', 'price', 'quantity', 'product_id', 'SKU']
      csv << header

      OrderItem.joins(:order).where(order: { kinds: origin }).each do |order_item|
        order = order_item.order

        case origin
        when 'bh_shopping'
          date = order_item.order_date_bh_shopping&.strftime('%d/%m/%Y')
        when 'lagoa_seca'
          date = order_item.order_date_lagoa_seca&.strftime('%d/%m/%Y')
        when 'rj'
          date = order_item.order_date_rj&.strftime('%d/%m/%Y')
        end

        csv << [
          order.tiny_order_id,
          date,
          order_item.price,
          order_item.quantity,
          order_item.product.present? ? order_item.product.shopify_product_id : '',
          order_item.sku
        ]
      end
    end

    puts "Arquivo CSV de pedidos salvo em: #{csv_file_path}"
  end

  def calculate_stock_quantity(product, origin)
    origin == 'lagoa_seca' ? product.stock_lagoa_seca.to_i : product.stock_bh_shopping.to_i
  end
end
