class ScheduleTinyToShopifyJob < ActiveJob::Base
  def perform
    data = (Date.today - 1).strftime('%d/%m/%Y')

    Tiny::Orders.get_all_orders('lagoa_seca', 'Entregue', 'process_for_shopify', '')
    Tiny::Orders.get_all_orders('bh_shopping', 'Entregue', 'process_for_shopify', '')
    Tiny::Orders.get_all_orders('rj', 'Entregue', 'process_for_shopify', '')
  end
end
