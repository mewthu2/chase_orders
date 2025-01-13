class MakeSpreadsheetJob < ApplicationJob
  queue_as :default

  require 'csv'
  require 'aws-sdk-s3'

  def perform(origin, kind)
    motor = Motor.find_or_initialize_by(job_name: "#{origin} - #{kind}")

    motor.start_time = Time.current
    motor.end_time = nil
    motor.save!

    csv_data = case kind
               when 'product'
                 generate_product_csv(origin)
               when 'order'
                 generate_order_csv(origin)
               else
                 raise ArgumentError, "Tipo inválido: #{kind}"
               end

    s3_url = save_to_s3(csv_data, origin, kind)

    motor.update!(
      end_time: Time.current,
      link: s3_url
    )
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
               when 'bh_shopping'
                 order_item.order_date_bh_shopping&.strftime('%d/%m/%Y')
               when 'lagoa_seca'
                order_item.order_date_lagoa_seca&.then do |date|
                  p "analizando #{date}"
                  next if date < Date.new(2024, 9, 1)
                  p date
                  date.strftime('%d/%m/%Y')
                end
               when 'rj'
                 order_item.order_date_rj&.strftime('%d/%m/%Y')
               end

        next if origin == 'lagoa_seca' && date.nil?

        csv << [
          order.tiny_order_id,
          date,
          order_item.price,
          order_item.quantity,
          order_item.product&.shopify_product_id || '',
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

    file_name = "public/#{origin}/#{kind}.csv"
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

    "https://#{bucket_name}.s3.amazonaws.com/#{file_name}"
  end  
end
