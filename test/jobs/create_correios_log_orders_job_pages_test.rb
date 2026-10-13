require 'test_helper'
require 'minitest/mock'

class CreateCorreiosLogOrdersJobPagesTest < ActiveSupport::TestCase
  test 'processes the orders of every page of the queue, once each' do
    retorno = { status: 'OK', numero_paginas: 2, pedidos: [{ pedido: { id: '1' } }, { pedido: { id: '2' } }, { pedido: { id: '3' } }] }.with_indifferent_access
    job = CreateCorreiosLogOrdersJob.new
    processed = []

    Tiny::Orders.stub(:get_all_orders_response, retorno) do
      job.stub(:process_order, ->(order) { processed << order[:pedido][:id] }) do
        job.create_correios_log_orders
      end
    end

    assert_equal %w[1 2 3], processed
  end
end
