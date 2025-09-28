module ProductsHelper
  def format_product_name(product)
    if product.shopify_product_name.present?
      truncate(product.shopify_product_name, length: 60)
    else
      "Produto ##{product.id}"
    end
  end

  def format_product_name_for_correction(product)
    return 'Produto sem nome' unless product
    
    if product.shopify_product_name.present?
      truncate(product.shopify_product_name, length: 50)
    else
      "SKU: #{product.sku}"
    end
  end

  def get_stock_for_location(product, location)
    case location
    when 'lagoa_seca'
      product.stock_lagoa_seca&.to_i || 0
    when 'bh_shopping'
      product.stock_bh_shopping&.to_i || 0
    when 'rj'
      product.stock_rj&.to_i || 0
    when 'fortaleza_rio_mar'
      product.stock_fortaleza_rio_mar&.to_i || 0
    when 'porto_alegre_bourbon'
      product.stock_porto_alegre_bourbon&.to_i || 0
    when 'eldorado_sp'
      product.stock_eldorado_sp&.to_i || 0
    else
      0
    end
  end

  def stock_badge_class(stock_value)
    stock = extract_stock_value(stock_value)
    
    case stock
    when 0
      'bg-danger text-white'
    when 1..5
      'bg-warning text-dark'
    when 6..20
      'bg-info text-dark'
    else
      'bg-success text-dark'
    end
  end

  def stock_icon_class(stock)
    stock_value = extract_stock_value(stock)
    
    case stock_value
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
    if product.respond_to?(:stock_source)
      case product.stock_source
      when 'shopify_real_time'
        content_tag :span, class: "badge bg-success text-white px-2 py-1" do
          content_tag(:i, '', class: "fab fa-shopify me-1") + "Shopify"
        end
      when 'database_fallback'
        content_tag :span, class: "badge bg-warning text-dark px-2 py-1" do
          content_tag(:i, '', class: "fas fa-database me-1") + "Banco"
        end
      when 'no_shopify_id'
        content_tag :span, class: "badge bg-secondary text-white px-2 py-1" do
          content_tag(:i, '', class: "fas fa-exclamation-triangle me-1") + "N/A"
        end
      else
        content_tag :span, class: "badge bg-success text-white px-2 py-1" do
          content_tag(:i, '', class: "fab fa-shopify me-1") + "Shopify"
        end
      end
    else
      content_tag :span, class: "badge bg-success text-white px-2 py-1" do
        content_tag(:i, '', class: "fab fa-shopify me-1") + "Shopify"
      end
    end
  end

  def stock_for_location(product, location)
    case location
    when 'lagoa_seca'
      product.stock_lagoa_seca || 0
    when 'bh_shopping'
      product.stock_bh_shopping || 0
    when 'rj'
      product.stock_rj || 0
    when 'fortaleza_rio_mar'
      product.stock_fortaleza_rio_mar || 0
    when 'porto_alegre_bourbon'
      product.stock_porto_alegre_bourbon || 0
    when 'eldorado_sp'
      product.stock_eldorado_sp || 0
    else
      0
    end
  end

  def location_display_name(location)
    case location
    when 'lagoa_seca'
      'Lagoa Seca'
    when 'bh_shopping'
      'BH Shopping'
    when 'rj'
      'Rio de Janeiro'
    when 'fortaleza_rio_mar'
      'Fortaleza Rio Mar'
    when 'porto_alegre_bourbon'
      'Porto Alegre Bourbon'
    when 'eldorado_sp'
      'Eldorado SP'
    else
      location.humanize
    end
  end

  def extract_stock_value(stock_value)
    return 0 if stock_value.nil?
    
    if stock_value.is_a?(Hash)
      stock_value[:available_quantity] || stock_value['available_quantity'] || 0
    else
      stock_value.to_i
    end
  end

  def next_direction(column)
    if params[:sort] == column && params[:direction] == 'asc'
      'desc'
    else
      'asc'
    end
  end
end
