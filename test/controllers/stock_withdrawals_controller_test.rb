require 'test_helper'
require 'webmock/minitest'
require 'minitest/mock'

class StockWithdrawalsControllerTest < ActionDispatch::IntegrationTest
  GRAPHQL_URL = 'https://chasebrasil.myshopify.com/admin/api/2025-01/graphql.json'.freeze
  LEVELS_URL = %r{\Ahttps://chasebrasil\.myshopify\.com/admin/api/2025-01/inventory_levels\.json}

  def setup
    ENV['CHASE_ORDERS_TOKEN'] = 'fake-shopify-token'
    @admin = User.create!(name: 'Admin Retirada', email: 'admin_withdrawal@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @lagoa = Location.create!(slug: 'lagoa_seca', name: 'Lagoa Seca', shopify_location_id: '111')
    @bh = Location.create!(slug: 'bh_shopping', name: 'BH Shopping', shopify_location_id: '222')
    # com foto guardada, o live_stock não vai ao Shopify buscar imagem (o WebMock bloquearia)
    @a = Product.create!(sku: 'SKU-A', shopify_product_name: 'Camiseta Azul', shopify_inventory_item_id: '9001', stock_lagoa_seca: '10', image_url: 'https://cdn.example.com/a.png')
    @b = Product.create!(sku: 'SKU-B', shopify_product_name: 'Calça Preta', shopify_inventory_item_id: '9002', image_url: 'https://cdn.example.com/b.png')
    @unlinked = Product.create!(sku: 'SEM-ID', shopify_product_name: 'Sem vínculo')
    sign_in @admin
  end

  def valid_params(items: nil, **header)
    { stock_withdrawal: {
      withdrawal_date: '2026-09-21', reason: 'damaged', notes: 'Caixa molhada',
      items: items || { '0' => { product_id: @a.id, location_id: @lagoa.id, quantity: '2' }, '1' => { product_id: @a.id, location_id: @bh.id, quantity: '3' } }
    }.merge(header) }
  end

  def draft(items: [[@a, @lagoa, 2]])
    withdrawal = StockWithdrawal.new(user: @admin, withdrawal_date: Date.new(2026, 9, 21), reason: 'damaged')
    items.each { |product, location, quantity| withdrawal.items.build(product: product, location: location, quantity: quantity) }
    withdrawal.save!
    withdrawal
  end

  def stub_shopify(available: { '111' => { '9001' => 10 } })
    levels = stub_request(:get, LEVELS_URL).to_return do |request|
      query = Addressable::URI.parse(request.uri).query_values
      rows = query['inventory_item_ids'].split(',').filter_map do |id|
        quantity = available.dig(query['location_ids'], id)
        { inventory_item_id: id.to_i, location_id: query['location_ids'].to_i, available: quantity } if quantity
      end
      { body: { inventory_levels: rows }.to_json, headers: { 'Content-Type' => 'application/json' } }
    end
    adjust = stub_request(:post, GRAPHQL_URL).to_return(
      body: { data: { inventoryAdjustQuantities: { userErrors: [], inventoryAdjustmentGroup: { id: 'gid://shopify/InventoryAdjustmentGroup/1' } } } }.to_json,
      headers: { 'Content-Type' => 'application/json' }
    )
    [levels, adjust]
  end

  test 'user without the stock_withdrawals permission is redirected everywhere' do
    profile = Profile.create!(name: 'Sem Retirada')
    user = User.create!(name: 'Sem Acesso', email: 'sem_withdrawal@example.com', password: 'password123')
    user.profiles << profile
    withdrawal = draft
    sign_in user

    get stock_withdrawals_path
    assert_redirected_to root_path
    post complete_stock_withdrawal_path(withdrawal)
    assert_redirected_to root_path
    assert withdrawal.reload.draft?
  end

  test 'index lists the withdrawals and filters by status' do
    draft
    done = draft(items: [[@b, @bh, 1]])
    done.update_columns(status: StockWithdrawal.statuses[:completed])

    get stock_withdrawals_path
    assert_response :success
    assert_select 'tbody tr', count: 2

    get stock_withdrawals_path(status: 'completed')
    assert_select 'tbody tr', count: 1
    assert_select 'tbody', text: /Concluída/
  end

  test 'new form has the reason, every location and the product search' do
    get new_stock_withdrawal_path

    assert_response :success
    assert_select 'select[name="stock_withdrawal[reason]"] option', count: StockWithdrawal::REASONS.size
    assert_select 'input[name="location_ids[]"]', count: Location.count
    assert_select '#productSearchInput'
    assert_select '#itemsTable'
  end

  test 'the form loads the live Shopify stock and the photo, and warns when the quantity is above it' do
    get new_stock_withdrawal_path

    assert_includes response.body, live_stock_stock_withdrawals_path
    assert_match(/Acima do disponível/, response.body)
    assert_match(/product-photo/, response.body)
    refute_match(/estoque: /, response.body, 'o estoque local desatualizado não é mais exibido')
  end

  test 'create saves a draft with one item per product and location and never touches Shopify' do
    shopify = stub_shopify

    assert_difference ['StockWithdrawal.count'], 1 do
      assert_difference 'StockWithdrawalItem.count', 2 do
        post stock_withdrawals_path, params: valid_params
      end
    end

    withdrawal = StockWithdrawal.last
    assert withdrawal.draft?
    assert_equal @admin, withdrawal.user
    assert_equal 'damaged', withdrawal.reason
    assert_equal 5, withdrawal.total_quantity
    assert_redirected_to stock_withdrawal_path(withdrawal)
    assert_not_requested shopify.first
    assert_not_requested shopify.last
    follow_redirect!
    assert_select '.flash-messages-container .alert-success', text: /rascunho/i
  end

  test 'blank quantities are ignored, so the grid can send empty cells' do
    items = { '0' => { product_id: @a.id, location_id: @lagoa.id, quantity: '2' }, '1' => { product_id: @a.id, location_id: @bh.id, quantity: '' } }

    assert_difference 'StockWithdrawalItem.count', 1 do
      post stock_withdrawals_path, params: valid_params(items: items)
    end
  end

  test 'create without items re-renders with the error and keeps what was typed' do
    assert_no_difference 'StockWithdrawal.count' do
      post stock_withdrawals_path, params: valid_params(items: {}, notes: 'Não perder isto')
    end

    assert_response :unprocessable_entity
    assert_select '.form-error-box', text: /pelo menos um item/
    assert_select 'textarea[name="stock_withdrawal[notes]"]', text: /Não perder isto/
  end

  test 'a product without a Shopify inventory id is refused with its SKU' do
    items = { '0' => { product_id: @unlinked.id, location_id: @lagoa.id, quantity: '1' } }

    assert_no_difference 'StockWithdrawal.count' do
      post stock_withdrawals_path, params: valid_params(items: items)
    end

    assert_response :unprocessable_entity
    assert_select '.form-error-box', text: /SEM-ID/
  end

  test 'edit and update replace the items of a draft' do
    withdrawal = draft(items: [[@a, @lagoa, 2]])

    get edit_stock_withdrawal_path(withdrawal)
    assert_response :success
    assert_select "input[name='stock_withdrawal[items][0][quantity]'], script", minimum: 1

    patch stock_withdrawal_path(withdrawal), params: valid_params(items: {
      '0' => { product_id: @a.id, location_id: @lagoa.id, quantity: '7' },
      '1' => { product_id: @b.id, location_id: @bh.id, quantity: '1' }
    }, reason: 'correction')

    assert_redirected_to stock_withdrawal_path(withdrawal)
    withdrawal.reload
    assert_equal 'correction', withdrawal.reason
    assert_equal [[@a.id, @lagoa.id, 7], [@b.id, @bh.id, 1]], withdrawal.items.order(:id).map { |i| [i.product_id, i.location_id, i.quantity] }
  end

  test 'an invalid update keeps the original items' do
    withdrawal = draft(items: [[@a, @lagoa, 2]])

    patch stock_withdrawal_path(withdrawal), params: valid_params(items: {})

    assert_response :unprocessable_entity
    assert_equal 1, withdrawal.reload.items.count
  end

  test 'a completed withdrawal cannot be edited or updated (everything was already sent to Shopify)' do
    withdrawal = draft
    withdrawal.update_columns(status: StockWithdrawal.statuses[:completed])

    get edit_stock_withdrawal_path(withdrawal)
    assert_redirected_to stock_withdrawal_path(withdrawal)
    patch stock_withdrawal_path(withdrawal), params: valid_params
    assert_redirected_to stock_withdrawal_path(withdrawal)
    assert_equal 1, withdrawal.reload.items.count
  end

  test 'a draft can be deleted without any Shopify warning' do
    withdrawal = draft

    delete stock_withdrawal_path(withdrawal)

    follow_redirect!
    assert_select '.flash-messages-container .alert-success', text: /Rascunho.*excluído/
  end

  test 'once integrated with Shopify a withdrawal can no longer be deleted, in any status' do
    %i[processing completed partially_failed partially_completed reverted].each do |status|
      withdrawal = draft
      withdrawal.update_columns(status: StockWithdrawal.statuses[status], updated_at: 30.minutes.ago)

      assert_no_difference ['StockWithdrawal.count', 'StockWithdrawalItem.count'] do
        delete stock_withdrawal_path(withdrawal)
      end

      assert_redirected_to stock_withdrawal_path(withdrawal)
      follow_redirect!
      assert_select '.flash-messages-container .alert-danger', text: /integrada com o Shopify.*Reverter/m
    end
  end

  test 'the delete button only exists for drafts, in the list and on the page' do
    pending = draft
    others = %i[completed partially_failed partially_completed reverted processing].map do |status|
      withdrawal = draft(items: [[@b, @bh, 1]])
      withdrawal.update_columns(status: StockWithdrawal.statuses[status], updated_at: 1.minute.ago)
      withdrawal
    end

    get stock_withdrawals_path
    assert_select "form[action='#{stock_withdrawal_path(pending)}'][method=post] input[name=_method][value=delete]", count: 1
    others.each { |w| assert_select "form[action='#{stock_withdrawal_path(w)}'] input[name=_method][value=delete]", count: 0, message: "lista: #{w.status}" }

    get stock_withdrawal_path(pending)
    assert_select "form[action='#{stock_withdrawal_path(pending)}'] input[name=_method][value=delete]", count: 1
    others.each do |w|
      get stock_withdrawal_path(w)
      assert_select "form[action='#{stock_withdrawal_path(w)}'] input[name=_method][value=delete]", count: 0, message: "página: #{w.status}"
    end
  end

  # ---- retirada com falhas: editar e retirar as linhas não concluídas ----

  def partially_failed_withdrawal
    withdrawal = draft(items: [[@a, @lagoa, 2], [@b, @lagoa, 5]])
    done, failed = withdrawal.items.to_a
    done.update!(status: :done, available_before: 10, withdrawn_at: Time.current)
    failed.update!(status: :failed, error_message: 'Estoque insuficiente: disponível 0, retirada 5')
    withdrawal.update_columns(status: StockWithdrawal.statuses[:partially_failed], reason: 'damaged')
    [withdrawal, done, failed]
  end

  test 'a partially failed withdrawal can be edited: done lines are shown locked, failed ones are in the grid with their error' do
    withdrawal, = partially_failed_withdrawal

    get edit_stock_withdrawal_path(withdrawal)

    assert_response :success
    assert_select '#lockedItems tbody tr', count: 1
    assert_select '#lockedItems', text: /SKU-A/
    assert_includes response.body, 'Estoque insuficiente: disponível 0, retirada 5'
    assert_select 'input#stock_withdrawal_withdrawal_date[disabled]'
    assert_select 'select#stock_withdrawal_reason[disabled]'
    assert_select 'textarea[name="stock_withdrawal[notes]"]:not([disabled])'
  end

  test 'updating a partially failed withdrawal replaces only the pending/failed lines and keeps the done ones untouched' do
    withdrawal, done, failed = partially_failed_withdrawal

    patch stock_withdrawal_path(withdrawal), params: valid_params(items: {
      '0' => { product_id: @b.id, location_id: @bh.id, quantity: '2' },
      '1' => { product_id: @a.id, location_id: @bh.id, quantity: '1' }
    }, notes: 'Ajustei local e quantidade')

    assert_redirected_to stock_withdrawal_path(withdrawal)
    withdrawal.reload
    assert withdrawal.partially_failed?
    assert_equal done.id, withdrawal.items.find_by(status: :done).id, 'a linha concluída não é recriada'
    assert_nil StockWithdrawalItem.find_by(id: failed.id)
    assert_equal [[@a.id, @bh.id, 1], [@b.id, @bh.id, 2]], withdrawal.items.pending.order(:product_id).map { |i| [i.product_id, i.location_id, i.quantity] }
    assert_equal 'Ajustei local e quantidade', withdrawal.notes
  end

  test 'date and reason cannot be changed once lines were withdrawn' do
    withdrawal, = partially_failed_withdrawal

    patch stock_withdrawal_path(withdrawal), params: valid_params(
      items: { '0' => { product_id: @b.id, location_id: @bh.id, quantity: '1' } },
      reason: 'marketing', withdrawal_date: '2030-01-01', notes: 'só isto muda'
    )

    withdrawal.reload
    assert_equal 'damaged', withdrawal.reason
    assert_equal Date.new(2026, 9, 21), withdrawal.withdrawal_date
    assert_equal 'só isto muda', withdrawal.notes
  end

  test 'removing every failed line completes the withdrawal, since only done lines are left' do
    withdrawal, = partially_failed_withdrawal

    patch stock_withdrawal_path(withdrawal), params: valid_params(items: {})

    assert_redirected_to stock_withdrawal_path(withdrawal)
    withdrawal.reload
    assert withdrawal.completed?
    assert_not_nil withdrawal.completed_at
    assert_equal 1, withdrawal.items.count
  end

  test 'a line that repeats a product and location already withdrawn is refused and nothing changes' do
    withdrawal, done, failed = partially_failed_withdrawal

    patch stock_withdrawal_path(withdrawal), params: valid_params(items: { '0' => { product_id: @a.id, location_id: @lagoa.id, quantity: '1' } })

    assert_response :unprocessable_entity
    assert_select '.form-error-box', text: /já está na lista/
    assert StockWithdrawalItem.exists?(failed.id), 'a linha falha original continua'
    assert StockWithdrawalItem.exists?(done.id)
  end

  test 'retrying withdraws the edited lines; without the negative option an insufficient line still fails' do
    withdrawal, = partially_failed_withdrawal
    levels, adjust = stub_shopify(available: { '111' => { '9002' => 0 } })

    post complete_stock_withdrawal_path(withdrawal)

    assert_requested levels
    assert_not_requested adjust
    assert withdrawal.reload.partially_failed?
    follow_redirect!
    assert_select '.flash-messages-container .alert-danger', text: /falhas/i
  end

  test 'retrying with the negative balance option withdraws the line anyway' do
    withdrawal, = partially_failed_withdrawal
    _, adjust = stub_shopify(available: { '111' => { '9002' => 0 } })

    post complete_stock_withdrawal_path(withdrawal), params: { allow_negative: '1' }

    assert_requested adjust, times: 1
    assert withdrawal.reload.completed?
    follow_redirect!
    assert_select '.flash-messages-container .alert-success', text: /Retirada concluída/
  end

  test 'the show page of a partially failed withdrawal offers edit, retry and the opt-in negative balance checkbox' do
    withdrawal, = partially_failed_withdrawal

    get stock_withdrawal_path(withdrawal)

    assert_select "a[href='#{edit_stock_withdrawal_path(withdrawal)}']", text: /Editar/
    assert_select "form[action='#{complete_stock_withdrawal_path(withdrawal)}'] input[type=checkbox][name=allow_negative]"
    assert_select "form[action='#{complete_stock_withdrawal_path(withdrawal)}']", text: /Tentar novamente/
    assert_select "form[action='#{complete_stock_withdrawal_path(withdrawal)}'][data-turbo-confirm*='negativo']"
  end

  test 'the negative balance checkbox only shows when there is something to retry' do
    draft_withdrawal = draft
    get stock_withdrawal_path(draft_withdrawal)
    assert_select 'input[name=allow_negative]', count: 0

    done = draft
    done.update_columns(status: StockWithdrawal.statuses[:completed])
    get stock_withdrawal_path(done)
    assert_select 'input[name=allow_negative]', count: 0
  end

  # ---- consultas: sem eager loading inútil nem N+1 (o Bullet só roda no dev, então contamos aqui) ----

  def sql_count(table)
    count = 0
    counter = ->(*, payload) { count += 1 if payload[:sql].match?(/FROM `#{table}`/) && payload[:name] != 'SCHEMA' }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') { yield }
    count
  end

  def many_failed_withdrawal
    withdrawal = draft(items: [[@a, @lagoa, 1], [@b, @lagoa, 2], [@a, @bh, 3], [@b, @bh, 4]])
    withdrawal.items.each { |item| item.update!(status: :failed, error_message: 'Estoque insuficiente') }
    withdrawal.update_columns(status: StockWithdrawal.statuses[:partially_failed])
    withdrawal
  end

  test 'the edit page does not eager load the locations of every line (it only needs their ids)' do
    withdrawal = many_failed_withdrawal

    assert_equal 1, sql_count('locations') { get edit_stock_withdrawal_path(withdrawal) }, 'só a lista de checkboxes de locations'
    assert_response :success
  end

  test 'the edit page loads the products of all lines in one query' do
    withdrawal = many_failed_withdrawal

    assert_operator sql_count('products') { get edit_stock_withdrawal_path(withdrawal) }, :<=, 1
  end

  test 'the show page loads locations and products once for all lines' do
    withdrawal = many_failed_withdrawal

    products = sql_count('products') { get stock_withdrawal_path(withdrawal) }
    locations = sql_count('locations') { get stock_withdrawal_path(withdrawal) }
    assert_operator products, :<=, 1
    assert_operator locations, :<=, 1
  end

  test 'redisplaying the form after a validation error does not query the product of each new line one by one' do
    withdrawal = many_failed_withdrawal
    items = (1..6).to_h { |n| [n.to_s, { product_id: (n.odd? ? @a.id : @b.id), location_id: [@lagoa, @bh][n % 2].id, quantity: (n + 5).to_s }] }
    items['6'][:quantity] = '0' # inválida: força a reexibição do formulário

    queries = sql_count('products') { patch stock_withdrawal_path(withdrawal), params: valid_params(items: items) }

    assert_response :unprocessable_entity
    assert_operator queries, :<=, 3, "produtos consultados #{queries}x para 6 linhas: N+1"
  end

  test 'the index does not query the location of each withdrawal line one by one' do
    3.times { many_failed_withdrawal }

    assert_operator sql_count('locations') { get stock_withdrawals_path }, :<=, 1
  end

  # ---- reverter uma linha já retirada (devolve o estoque no Shopify) ----

  def completed_withdrawal(items: [[@a, @lagoa, 2], [@b, @bh, 3]])
    withdrawal = draft(items: items)
    withdrawal.items.each { |item| item.update!(status: :done, available_before: 10, withdrawn_at: Time.current) }
    withdrawal.update_columns(status: StockWithdrawal.statuses[:completed], completed_at: Time.current)
    withdrawal
  end

  def stub_revert(user_errors: [])
    @revert_calls = []
    stub_request(:post, GRAPHQL_URL).to_return do |request|
      @revert_calls << JSON.parse(request.body)['variables']['input']
      data = { inventoryAdjustQuantities: { userErrors: user_errors, inventoryAdjustmentGroup: user_errors.empty? ? { id: 'gid://shopify/InventoryAdjustmentGroup/9' } : nil } }
      { body: { data: data }.to_json, headers: { 'Content-Type' => 'application/json' } }
    end
  end

  test 'reverting a done line returns the stock in Shopify and leaves the withdrawal partially completed' do
    withdrawal = completed_withdrawal
    item = withdrawal.items.first
    stub_revert

    post revert_stock_withdrawal_item_path(withdrawal, item)

    assert_redirected_to stock_withdrawal_path(withdrawal)
    assert_equal 2, @revert_calls.first['changes'].first['delta']
    assert item.reload.reverted?
    assert withdrawal.reload.partially_completed?
    follow_redirect!
    assert_select '.flash-messages-container .alert-success', text: /SKU-A revertida.*2 unidade\(s\).*Lagoa Seca/m
    assert_select '.page-subtitle', text: /Parcialmente concluída/
  end

  test 'reverting the last done line makes the withdrawal reverted' do
    withdrawal = completed_withdrawal(items: [[@a, @lagoa, 2]])
    stub_revert

    post revert_stock_withdrawal_item_path(withdrawal, withdrawal.items.first)

    assert withdrawal.reload.reverted?
  end

  test 'a rejection from Shopify keeps the line as done and shows the real message' do
    withdrawal = completed_withdrawal
    stub_revert(user_errors: [{ field: %w[input], message: 'Item não rastreado' }])

    post revert_stock_withdrawal_item_path(withdrawal, withdrawal.items.first)

    assert withdrawal.items.first.reload.done?
    assert withdrawal.reload.completed?
    follow_redirect!
    assert_select '.flash-messages-container .alert-danger', text: /Item não rastreado/
  end

  test 'a line that is not done cannot be reverted and Shopify is not called' do
    withdrawal = draft
    stub = stub_revert

    post revert_stock_withdrawal_item_path(withdrawal, withdrawal.items.first)

    assert_not_requested stub
    follow_redirect!
    assert_select '.flash-messages-container .alert-danger', text: /já foi retirada/
  end

  test 'the same line cannot be reverted twice' do
    withdrawal = completed_withdrawal
    item = withdrawal.items.first
    stub = stub_revert

    post revert_stock_withdrawal_item_path(withdrawal, item)
    post revert_stock_withdrawal_item_path(withdrawal, item)

    assert_requested stub, times: 1
    follow_redirect!
    assert_select '.flash-messages-container .alert-danger'
  end

  test 'a line of another withdrawal is not found' do
    withdrawal = completed_withdrawal
    other = completed_withdrawal(items: [[@b, @lagoa, 1]])
    stub = stub_revert

    post revert_stock_withdrawal_item_path(withdrawal, other.items.first)

    assert_response :not_found
    assert_not_requested stub
  end

  test 'reverting requires the stock_withdrawals permission' do
    withdrawal = completed_withdrawal
    profile = Profile.create!(name: 'Sem Reverter')
    user = User.create!(name: 'Sem Reverter', email: 'sem_revert@example.com', password: 'password123')
    user.profiles << profile
    stub = stub_revert
    sign_in user

    post revert_stock_withdrawal_item_path(withdrawal, withdrawal.items.first)

    assert_redirected_to root_path
    assert_not_requested stub
    assert withdrawal.items.first.reload.done?
  end

  test 'the show page has a revert button on each done line only, with a confirmation, and marks reverted lines' do
    withdrawal = completed_withdrawal(items: [[@a, @lagoa, 2], [@b, @bh, 3], [@a, @bh, 1]])
    done_a, reverted, done_b = withdrawal.items.to_a
    reverted.update!(status: :reverted, reverted_at: Time.current)
    withdrawal.update_columns(status: StockWithdrawal.statuses[:partially_completed])

    get stock_withdrawal_path(withdrawal)

    [done_a, done_b].each do |item|
      assert_select "form[action='#{revert_stock_withdrawal_item_path(withdrawal, item)}'][data-turbo-confirm*='devolv']", count: 1
    end
    assert_select "form[action='#{revert_stock_withdrawal_item_path(withdrawal, reverted)}']", count: 0
    assert_select 'tbody', text: /Revertido/
    assert_select '.page-subtitle', text: /Parcialmente concluída/
  end

  test 'a draft shows no revert button (nothing was withdrawn yet)' do
    withdrawal = draft

    get stock_withdrawal_path(withdrawal)

    assert_select "form[action*='/revert']", count: 0
  end

  test 'the list shows the partially completed and reverted statuses' do
    partial = completed_withdrawal
    partial.update_columns(status: StockWithdrawal.statuses[:partially_completed])
    reverted = completed_withdrawal(items: [[@b, @lagoa, 1]])
    reverted.update_columns(status: StockWithdrawal.statuses[:reverted])

    get stock_withdrawals_path
    assert_select 'tbody', text: /Parcialmente concluída/
    assert_select 'tbody', text: /Revertida/

    get stock_withdrawals_path(status: 'partially_completed')
    assert_select 'tbody tr', count: 1
  end

  test 'the show page with reverted lines does not query products or locations line by line' do
    withdrawal = completed_withdrawal(items: [[@a, @lagoa, 1], [@b, @lagoa, 2], [@a, @bh, 3], [@b, @bh, 4]])
    withdrawal.items.each { |item| item.update!(status: :reverted, reverted_at: Time.current) }

    assert_operator sql_count('products') { get stock_withdrawal_path(withdrawal) }, :<=, 1
    assert_operator sql_count('locations') { get stock_withdrawal_path(withdrawal) }, :<=, 1
  end
end
