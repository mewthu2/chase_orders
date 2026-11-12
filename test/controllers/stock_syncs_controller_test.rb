require 'test_helper'

class StockSyncsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(name: 'Admin Sync', email: 'admin_sync@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    Product.create!(sku: 'SYNC-404', shopify_product_name: 'Top Sumido')
    @attempt = Attempt.create!(kinds: :sync_correios_stock, status: :success, tracking: 'auto_execution:1',
                               message: 'Sincronização concluída com erros: 1/3 produtos atualizados. 2 falharam.',
                               params: { total: 3, success: 1, failed: 2, errors: [] }.to_json)
    @attempt.stock_sync_failures.create!(sku: 'SYNC-404', stage: 'correios', reason: 'Correios respondeu 404: Item não encontrado', created_at: Time.current)
    @attempt.stock_sync_failures.create!(sku: 'SYNC-RECUSA', stage: 'shopify', reason: 'Inventory item not stocked', created_at: Time.current)
  end

  test 'the run list links to the run and shows how many failed' do
    sign_in @admin
    get stock_syncs_path

    assert_response :success
    assert_select "a[href='#{stock_sync_path(@attempt)}']"
  end

  test 'the run page lists every failed product with the reason' do
    sign_in @admin
    get stock_sync_path(@attempt)

    assert_response :success
    assert_select '#pgt-main tbody tr', count: 2
    assert_select '#pgt-main tbody tr', text: /SYNC-404.*Top Sumido.*Item não encontrado/m
    assert_select '#pgt-main tbody tr', text: /SYNC-RECUSA.*not stocked/m
    assert_select "a[href='#{stock_sync_path(@attempt, format: :csv)}']"
  end

  test 'the spreadsheet has one line per failed product' do
    sign_in @admin
    get stock_sync_path(@attempt, format: :csv)

    assert_response :success
    lines = response.body.delete_prefix("﻿").lines
    assert_equal 3, lines.size
    assert_match(/"SYNC-404";"Top Sumido";"Consulta no Correios";"Correios respondeu 404/, lines[1])
  end

  test 'older runs fall back to the errors kept in params and warn the list is partial' do
    old = Attempt.create!(kinds: :sync_correios_stock, status: :success, tracking: 'auto_execution:2', message: 'Concluída com erros',
                          params: { total: 4184, success: 3786, failed: 398, errors: ['Erro ao consultar estoque do produto SYNC-404: 404'] }.to_json)
    sign_in @admin
    get stock_sync_path(old)

    assert_select '#pgt-main tbody tr', text: /SYNC-404.*Top Sumido/m
    assert_match(/Lista incompleta/, response.body)
  end
end
