class CreateCorreiosLogOrdersJob < ActiveJob::Base
  def perform
    create_correios_log_orders
  end

  def create_correios_log_orders
    orders = Tiny::Orders.get_orders('preparando_envio', 1)

    orders[:numero_paginas].times do |page|
      orders = Tiny::Orders.get_orders('preparando_envio', page)
      orders.each do |order|
        
      end
    end
  end
end
