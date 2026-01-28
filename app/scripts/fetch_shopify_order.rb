# Script para buscar um pedido específico da Shopify e ver seus dados
# Execute no console Rails: load 'app/scripts/fetch_shopify_order.rb'

class FetchShopifyOrder
  def self.call(order_id)
    puts "=" * 80
    puts "Buscando pedido #{order_id} da Shopify..."
    puts "=" * 80
    
    session = ShopifyAPI::Auth::Session.new(
      shop: 'chasebrasil.myshopify.com',
      access_token: ENV.fetch('BH_SHOPPING_TOKEN_APP')
    )

    begin
      # Busca o pedido completo
      order = ShopifyAPI::Order.find(
        session: session,
        id: 6622773477450
      )

      puts "\n📦 DADOS DO PEDIDO:"
      puts "-" * 80
      puts "ID: #{order.id}"
      puts "Name: #{order.name}"
      puts "Email: #{order.email}"
      puts "Total Price: #{order.total_price}"
      puts "Financial Status: #{order.financial_status}"
      puts "Fulfillment Status: #{order.fulfillment_status}"
      puts "Created At: #{order.created_at}"
      
      puts "\n👤 CUSTOMER:"
      puts "-" * 80
      if order.customer
        puts "Name: #{order.customer.first_name} #{order.customer.last_name}"
        puts "Email: #{order.customer.email}"
        puts "Phone: #{order.customer.phone}"
      else
        puts "Sem customer"
      end

      puts "\n📋 LINE ITEMS (#{order.line_items.count}):"
      puts "-" * 80
      order.line_items.each_with_index do |item, index|
        puts "#{index + 1}. #{item.name}"
        puts "   SKU: #{item.sku}"
        puts "   Price: #{item.price}"
        puts "   Quantity: #{item.quantity}"
        puts "   Total: #{item.price.to_f * item.quantity}"
        puts ""
      end

      puts "\n💳 NOTE ATTRIBUTES (onde podem estar os dados de pagamento):"
      puts "-" * 80
      if order.note_attributes && order.note_attributes.any?
        order.note_attributes.each do |attr|
          puts "#{attr.name}: #{attr.value}"
        end
      else
        puts "Sem note attributes"
      end

      puts "\n📝 NOTES:"
      puts "-" * 80
      puts order.note || "Sem notas"

      puts "\n💰 TRANSACTIONS:"
      puts "-" * 80
      if order.respond_to?(:transactions) && order.transactions.any?
        order.transactions.each do |transaction|
          puts "Kind: #{transaction.kind}"
          puts "Status: #{transaction.status}"
          puts "Amount: #{transaction.amount}"
          puts "Gateway: #{transaction.gateway}"
          puts "Authorization: #{transaction.authorization}"
          puts "-" * 40
        end
      else
        puts "Sem transactions disponíveis no objeto"
      end

      puts "\n🔍 METAFIELDS (se houver):"
      puts "-" * 80
      if order.respond_to?(:metafields)
        puts order.metafields.inspect
      else
        puts "Metafields não disponíveis"
      end

      puts "\n📄 TODOS OS ATRIBUTOS DO PEDIDO:"
      puts "-" * 80
      puts order.to_json

      puts "\n" + "=" * 80
      puts "✅ Pedido encontrado!"
      puts "=" * 80

      return order

    rescue ShopifyAPI::Errors::HttpResponseError => e
      puts "\n❌ Erro ao buscar pedido: #{e.message}"
      puts "Response: #{e.response}"
      return nil
    rescue StandardError => e
      puts "\n❌ Erro: #{e.message}"
      puts e.backtrace.first(5).join("\n")
      return nil
    end
  end
end

# Para executar:
# FetchShopifyOrder.call('6622991319114')
