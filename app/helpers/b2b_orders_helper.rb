module B2bOrdersHelper
  def tiny_order_url(order)
    return nil if order.tiny_reference_id.blank?

    base = order.sale? ? ENV.fetch('TINY_ORDER_URL', 'https://erp.tiny.com.br/vendas#edit/') : ENV.fetch('TINY_NOTA_FISCAL_URL', 'https://erp.tiny.com.br/notas_fiscais#edit/')
    "#{base}#{order.tiny_reference_id}"
  end
end
