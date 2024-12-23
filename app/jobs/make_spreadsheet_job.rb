class MakeSpreadsheetJob < ApplicationJob
  queue_as :default

  require 'csv'
  require 'aws-sdk-s3'

  def perform(origin, kind)
    case kind
    when 'product'
      csv_data = generate_product_csv(origin)
    when 'order'
      csv_data = generate_order_csv(origin)
    else
      raise ArgumentError, "Tipo inválido: #{kind}"
    end

    save_to_s3(csv_data, origin, kind)
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

  def save_to_s3(csv_data, origin, kind)
    s3_client = Aws::S3::Client.new(
      access_key_id: ENV.fetch('BUCKETEER_AWS_ACCESS_KEY_ID'),
      secret_access_key: ENV.fetch('BUCKETEER_AWS_SECRET_ACCESS_KEY'),
      region: ENV.fetch('BUCKETEER_AWS_REGION')
    )

    file_name = "#{origin}/#{kind}.csv"
    bucket_name = ENV.fetch('BUCKETEER_BUCKET_NAME')

    begin
      s3_client.head_object(bucket: bucket_name, key: file_name)
      s3_client.delete_object(bucket: bucket_name, key: file_name)
    rescue Aws::S3::Errors::NotFound
    end

    s3_client.put_object(
      bucket: bucket_name,
      key: file_name,
      body: csv_data,
      content_type: 'text/csv'
    )

    signer = Aws::S3::Presigner.new(client: s3_client)
    signer.presigned_url(:get_object, bucket: bucket_name, key: file_name, expires_in: 3600)
  end
end
