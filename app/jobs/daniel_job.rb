class DanielJob < ActiveJob::Base
  queue_as :default

  def perform
    Tiny::Orders.get_all_orders('bh_shopping', 'Entregue', 'update_orders', '')
  end
end