module ProductsHelper
  def location_name(location_key)
    User.location_name(location_key)
  end

  def get_stock_for_location(product, location)
    # Priorizar estoque real da Shopify se disponível
    return product.real_stock if product.respond_to?(:real_stock)
    
    # Fallback para estoque do banco
    case location
    when 'lagoa_seca'
      product.stock_lagoa_seca&.to_i || 0
    when 'bh_shopping'
      product.stock_bh_shopping&.to_i || 0
    when 'rj'
      product.stock_rj&.to_i || 0
    when 'log'
      product.stock_log&.to_i || 0
    else
      0
    end
  end

  def stock_badge_class(stock)
    stock_value = stock.to_i
    return 'bg-danger' if stock.nil? || stock_value == 0
    return 'bg-warning' if stock_value < 10
    'bg-success'
  end

  def stock_status_text(stock)
    stock_value = stock.to_i
    return 'Sem estoque' if stock.nil? || stock_value == 0
    return 'Estoque baixo' if stock_value < 10
    'Estoque normal'
  end

  def format_product_name(product)
    if product.shopify_product_name.present?
      product.shopify_product_name
    else
      "Produto #{product.sku}"
    end
  end

  def stock_icon_class(stock)
    stock_value = stock.to_i
    return 'fas fa-times-circle text-danger' if stock.nil? || stock_value == 0
    return 'fas fa-exclamation-triangle text-warning' if stock_value < 10
    'fas fa-check-circle text-success'
  end

  def stock_source_indicator(product)
    if product.respond_to?(:stock_source)
      case product.stock_source
      when 'real_time'
        content_tag :small, class: "text-success" do
          content_tag(:i, "", class: "fas fa-sync me-1") + "Tempo Real"
        end
      when 'fallback'
        content_tag :small, class: "text-warning" do
          content_tag(:i, "", class: "fas fa-database me-1") + "Cache Local"
        end
      when 'no_shopify_id'
        content_tag :small, class: "text-danger" do
          content_tag(:i, "", class: "fas fa-exclamation-triangle me-1") + "Sem Shopify ID"
        end
      else
        content_tag :small, class: "text-info" do
          content_tag(:i, "", class: "fas fa-question me-1") + "Desconhecido"
        end
      end
    else
      content_tag :small, class: "text-secondary" do
        content_tag(:i, "", class: "fas fa-database me-1") + "Banco de Dados"
      end
    end
  end
end
