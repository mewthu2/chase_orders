module ProductsHelper
  def format_product_name(product)
    return "Produto sem nome" unless product.shopify_product_name.present?
    
    # Extrair a variante do SKU (última parte após o último hífen)
    variant = product.sku.split('-').last if product.sku.present?
    
    if variant.present? && variant.length <= 3 # Assumindo que variantes são curtas (G, M, P, etc.)
      "#{product.shopify_product_name} - #{variant} (SKU: #{product.sku})"
    else
      "#{product.shopify_product_name} (SKU: #{product.sku})"
    end
  end

  def format_product_name_for_correction(product)
    return "Produto sem nome" unless product.shopify_product_name.present?
    
    # Extrair a variante do SKU (última parte após o último hífen)
    variant = product.sku.split('-').last if product.sku.present?
    
    if variant.present? && variant.length <= 3 # Assumindo que variantes são curtas (G, M, P, etc.)
      "#{product.shopify_product_name} - #{variant}"
    else
      product.shopify_product_name
    end
  end

  def get_stock_for_location(product, location)
    case location
    when 'lagoa_seca'
      product.stock_lagoa_seca
    when 'bh_shopping'
      product.stock_bh_shopping
    when 'rj'
      product.stock_rj
    else
      nil
    end
  end

  def stock_badge_class(stock)
    return 'bg-secondary' if stock.nil?
    
    case stock.to_i
    when 0
      'bg-danger'
    when 1..5
      'bg-warning'
    when 6..20
      'bg-info'
    else
      'bg-success'
    end
  end

  def stock_icon_class(stock)
    return 'fas fa-question-circle text-secondary' if stock.nil?
    
    case stock.to_i
    when 0
      'fas fa-times-circle text-danger'
    when 1..5
      'fas fa-exclamation-triangle text-warning'
    when 6..20
      'fas fa-info-circle text-info'
    else
      'fas fa-check-circle text-success'
    end
  end

  def stock_source_indicator(product)
    if product.shopify_inventory_item_id.present?
      content_tag :span, class: "badge bg-success text-dark px-2 py-1" do
        content_tag(:i, "", class: "fab fa-shopify me-1") + "Shopify"
      end
    else
      content_tag :span, class: "badge bg-secondary text-white px-2 py-1" do
        content_tag(:i, "", class: "fas fa-database me-1") + "Local"
      end
    end
  end
end
