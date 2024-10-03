class SyncOrdersSituationJob < ActiveJob::Base
  def perform
    sync_tiny_orders_lagoa_seca
    sync_tiny_orders_bh_shopping
  end

  def sync_tiny_orders_lagoa_seca
    Tiny::Orders.get_all_orders('lagoa_seca', '', 'update_orders', '')
  end

  def sync_tiny_orders_bh_shopping
    Tiny::Orders.get_all_orders('bh_shopping', '', 'update_orders', '')
  end
end
