class SyncOrdersSituationJob < ActiveJob::Base
  def perform
    data = (Date.today - 1).strftime('%d/%m/%Y')

    sync_tiny_orders_lagoa_seca
    sync_tiny_orders_bh_shopping
    sync_tiny_orders_rj
  end

  def sync_tiny_orders_lagoa_seca
    Tiny::Orders.get_all_orders('lagoa_seca', 'Entregue', 'update_orders', data)
  end

  def sync_tiny_orders_bh_shopping
    Tiny::Orders.get_all_orders('bh_shopping', 'Entregue', 'update_orders', data)
  end

  def sync_tiny_orders_rj
    Tiny::Orders.get_all_orders('rj', 'Entregue', 'update_orders', data)
  end
end
