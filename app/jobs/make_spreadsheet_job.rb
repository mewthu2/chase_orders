class MakeSpreadsheetJob < ApplicationJob
  queue_as :default

  require 'csv'

  def perform(origin, kind)
    case kind
    when 'product'
      generate_product_csv(origin)
    when 'order'
      generate_order_csv(origin)
    else
      raise ArgumentError, "Tipo inválido: #{kind}"
    end
  end

  private

  def generate_product_csv(origin)
    CSV.generate(headers: true) do |csv|
      csv << ['product_id', 'title', 'SKU', 'price', 'created_at', 'stock_quantity']
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
  end

  def generate_order_csv(origin)
    CSV.generate(headers: true) do |csv|
      csv << ['order_number', 'date', 'price', 'quantity', 'product_id', 'SKU']
      OrderItem.joins(:order).where(order: { kinds: origin }).each do |order_item|
        order = order_item.order
        date = case origin
               when 'bh_shopping' then order_item.order_date_bh_shopping&.strftime('%d/%m/%Y')
               when 'lagoa_seca' then order_item.order_date_lagoa_seca&.strftime('%d/%m/%Y')
               when 'rj' then order_item.order_date_rj&.strftime('%d/%m/%Y')
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
  end

  def calculate_stock_quantity(product, origin)
    case origin
    when 'lagoa_seca'
      product.stock_lagoa_seca.to_i
    when 'bh_shopping'
      product.stock_bh_shopping.to_i
    when 'rj'
      product.stock_rj.to_i
    end
  end
end
