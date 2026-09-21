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

  test 'a completed or partially failed withdrawal can be deleted, with a warning that Shopify stock is not restored' do
    %i[completed partially_failed].each do |status|
      withdrawal = draft
      withdrawal.update_columns(status: StockWithdrawal.statuses[status])

      assert_difference ['StockWithdrawal.count', 'StockWithdrawalItem.count'], -1 do
        delete stock_withdrawal_path(withdrawal)
      end

      assert_redirected_to stock_withdrawals_path
      follow_redirect!
      assert_select '.flash-messages-container .alert', text: /NÃO foi devolvido/
    end
  end

  test 'deleting a draft does not need the Shopify warning' do
    withdrawal = draft

    delete stock_withdrawal_path(withdrawal)

    follow_redirect!
    assert_select '.flash-messages-container .alert-success', text: /Rascunho.*excluído/
    assert_select '.flash-messages-container .alert', text: /NÃO foi devolvido/, count: 0
  end

  test 'deleting a withdrawal that was already processed is recorded in the audit log and never calls Shopify' do
    withdrawal = draft(items: [[@a, @lagoa, 2], [@a, @bh, 3]])
    withdrawal.update_columns(status: StockWithdrawal.statuses[:completed])
    levels, adjust = stub_shopify

    assert_difference 'Log.count', 1 do
      delete stock_withdrawal_path(withdrawal)
    end

    log = Log.last
    assert_equal 'stock_withdrawal', log.resource_type
    assert_equal 'delete', log.action_type
    assert_equal @admin, log.user
    assert_equal 'completed', log.details_parsed['status']
    assert_equal 5, log.details_parsed['total_quantity']
    assert_not_requested levels
    assert_not_requested adjust
  end

  test 'a withdrawal being processed right now cannot be deleted' do
    withdrawal = draft
    withdrawal.update_columns(status: StockWithdrawal.statuses[:processing], updated_at: 1.minute.ago)

    assert_no_difference 'StockWithdrawal.count' do
      delete stock_withdrawal_path(withdrawal)
    end

    follow_redirect!
    assert_select '.flash-messages-container .alert-danger', text: /processamento/
  end

  test 'a stale processing withdrawal can be deleted' do
    withdrawal = draft
    withdrawal.update_columns(status: StockWithdrawal.statuses[:processing], updated_at: 11.minutes.ago)

    assert_difference 'StockWithdrawal.count', -1 do
      delete stock_withdrawal_path(withdrawal)
    end
  end

  test 'the delete button shows for every status except processing, with a stronger confirmation once processed' do
    pending = draft
    done = draft(items: [[@b, @bh, 1]])
    done.update_columns(status: StockWithdrawal.statuses[:completed])
    busy = draft(items: [[@a, @bh, 1]])
    busy.update_columns(status: StockWithdrawal.statuses[:processing], updated_at: 1.minute.ago)

    get stock_withdrawals_path
    assert_select "form[action='#{stock_withdrawal_path(pending)}'][data-turbo-confirm]"
    assert_select "form[action='#{stock_withdrawal_path(done)}'][data-turbo-confirm*='NÃO devolve']"
    assert_select "form[action='#{stock_withdrawal_path(busy)}']", count: 0

    get stock_withdrawal_path(done)
    assert_select "form[action='#{stock_withdrawal_path(done)}'][data-turbo-confirm*='NÃO devolve']"
  end

  test 'a draft can be destroyed' do
    withdrawal = draft

    assert_difference 'StockWithdrawal.count', -1 do
      delete stock_withdrawal_path(withdrawal)
    end
    assert_redirected_to stock_withdrawals_path
  end

  test 'complete withdraws from Shopify right away and shows the result' do
    withdrawal = draft(items: [[@a, @lagoa, 2]])
    levels, adjust = stub_shopify

    assert_no_enqueued_jobs do
      post complete_stock_withdrawal_path(withdrawal)
    end

    assert_requested levels
    assert_requested adjust, times: 1
    assert withdrawal.reload.completed?
    assert_redirected_to stock_withdrawal_path(withdrawal)
    follow_redirect!
    assert_select '.flash-messages-container .alert-success', text: /Retirada concluída/
    assert_select 'tbody', text: /Retirado/
  end

  test 'complete with a failing line reports it and lets you try again' do
    withdrawal = draft(items: [[@a, @lagoa, 20]])
    stub_shopify # disponível 10 < 20

    post complete_stock_withdrawal_path(withdrawal)

    assert withdrawal.reload.partially_failed?
    follow_redirect!
    assert_select '.flash-messages-container .alert-danger', text: /falhas/i
    assert_select 'tbody', text: /Estoque insuficiente/
    assert_select "form[action='#{complete_stock_withdrawal_path(withdrawal)}']", text: /Tentar novamente/
  end

  test 'complete on an already completed withdrawal is refused and Shopify is not called' do
    withdrawal = draft
    withdrawal.update_columns(status: StockWithdrawal.statuses[:completed])
    levels, adjust = stub_shopify

    post complete_stock_withdrawal_path(withdrawal)

    assert_redirected_to stock_withdrawal_path(withdrawal)
    assert_not_requested levels
    assert_not_requested adjust
    follow_redirect!
    assert_select '.flash-messages-container .alert-danger'
  end

  test 'show asks for confirmation before withdrawing and explains there is no undo' do
    withdrawal = draft

    get stock_withdrawal_path(withdrawal)

    assert_select "form[action='#{complete_stock_withdrawal_path(withdrawal)}'][data-turbo-confirm*='desfazer']"
  end

  test 'search_product returns only products linked to Shopify, with photo, and no stale local stock' do

    get search_product_stock_withdrawals_path, params: { query: 'camiseta' }
    json = JSON.parse(response.body)

    assert_equal ['SKU-A'], json['products'].map { |p| p['sku'] }
    assert_equal 'https://cdn.example.com/a.png', json['products'].first['image_url']
    refute_includes json['products'].first.keys, 'stock', 'o estoque vem ao vivo do Shopify (live_stock), não do banco local'

    get search_product_stock_withdrawals_path, params: { query: 'SEM-ID' }
    assert_empty JSON.parse(response.body)['products']
  end

  # ---- estoque ao vivo do Shopify (por produto x location marcada) ----

  def live(products: [@a, @b], locations: [@lagoa, @bh])
    get live_stock_stock_withdrawals_path, params: { product_ids: products.map(&:id), location_ids: locations.map(&:id) }
    JSON.parse(response.body)
  end

  def stub_levels_only(available)
    stub_request(:get, LEVELS_URL).to_return do |request|
      query = Addressable::URI.parse(request.uri).query_values
      location = query['location_ids']
      raise 'falha simulada' if available[location] == :error

      rows = query['inventory_item_ids'].split(',').filter_map do |id|
        next unless available[location]&.key?(id)

        { inventory_item_id: id.to_i, location_id: location.to_i, available: available[location][id] }
      end
      { body: { inventory_levels: rows }.to_json, headers: { 'Content-Type' => 'application/json' } }
    end
  end

  test 'live_stock returns the real Shopify availability per product and per selected location' do
    stub_levels_only('111' => { '9001' => 10, '9002' => 4 }, '222' => { '9001' => 25 })

    json = live

    assert json['success']
    assert_equal 10, json['stock'][@a.id.to_s][@lagoa.id.to_s]
    assert_equal 4, json['stock'][@b.id.to_s][@lagoa.id.to_s]
    assert_equal 25, json['stock'][@a.id.to_s][@bh.id.to_s]
    assert_nil json['stock'][@b.id.to_s][@bh.id.to_s], 'não estocado na location = null, nunca 0'
  end

  test 'it uses the value from Shopify, not the stale local column' do
    @a.update!(stock_lagoa_seca: '999')
    stub_levels_only('111' => { '9001' => 3 })

    assert_equal 3, live(products: [@a], locations: [@lagoa])['stock'][@a.id.to_s][@lagoa.id.to_s]
  end

  test 'only the selected locations are queried, one Shopify read per location' do
    levels = stub_levels_only('111' => { '9001' => 10, '9002' => 1 }, '222' => { '9001' => 2 })

    live(locations: [@lagoa])
    assert_requested levels, times: 1

    live(locations: [@lagoa, @bh])
    assert_requested levels, times: 3
  end

  test 'a Shopify failure in one location does not break the others and is reported for that location' do
    stub_levels_only('111' => { '9001' => 10 }, '222' => :error)

    json = live(products: [@a])

    assert json['success']
    assert_equal 10, json['stock'][@a.id.to_s][@lagoa.id.to_s]
    assert_nil json['stock'][@a.id.to_s][@bh.id.to_s]
    assert json['errors'][@bh.id.to_s].present?
    refute_includes json['errors'].keys, @lagoa.id.to_s
  end

  test 'an untracked item in a location comes back as null' do
    stub_levels_only('111' => { '9001' => nil })

    assert_nil live(products: [@a], locations: [@lagoa])['stock'][@a.id.to_s][@lagoa.id.to_s]
  end

  test 'a location without a Shopify id is reported as an error' do
    orphan = Location.create!(slug: 'nova', name: 'Nova', shopify_location_id: nil)
    levels = stub_levels_only({})

    json = live(products: [@a], locations: [orphan])

    assert_match(/sem ID do Shopify/, json['errors'][orphan.id.to_s])
    assert_not_requested levels
  end

  test 'products not linked to Shopify are ignored' do
    stub_levels_only('111' => { '9001' => 10 })

    json = live(products: [@a, @unlinked], locations: [@lagoa])

    assert_equal [@a.id.to_s], json['stock'].keys
  end

  test 'it returns the product photo: the stored one directly, the missing one looked up in Shopify' do
    @b.update!(image_url: nil)
    stub_levels_only('111' => { '9001' => 10, '9002' => 4 })
    lookups = []

    Shopify::Products.stub(:update_product_with_shopify_id, ->(product) { lookups << [:id, product.sku]; product.update!(shopify_product_id: '55') }) do
      Shopify::Products.stub(:update_product_with_image_url, ->(product) { lookups << [:image, product.sku]; product.update!(image_url: 'https://cdn.example.com/b.png') }) do
        json = live(locations: [@lagoa])

        assert_equal 'https://cdn.example.com/a.png', json['images'][@a.id.to_s]
        assert_equal 'https://cdn.example.com/b.png', json['images'][@b.id.to_s]
      end
    end
    assert_equal [[:id, 'SKU-B'], [:image, 'SKU-B']], lookups, 'só o produto sem foto vai ao Shopify buscar a imagem'
  end

  test 'a failure looking up the photo does not break the live stock' do
    @a.update!(image_url: nil)
    stub_levels_only('111' => { '9001' => 10 })

    Shopify::Products.stub(:update_product_with_shopify_id, ->(_product) { raise 'Shopify fora do ar' }) do
      json = live(products: [@a], locations: [@lagoa])

      assert json['success']
      assert_equal 10, json['stock'][@a.id.to_s][@lagoa.id.to_s]
      assert_nil json['images'][@a.id.to_s]
    end
  end

  test 'live_stock without products or locations returns empty results and does not call Shopify' do
    levels = stub_levels_only({})

    get live_stock_stock_withdrawals_path
    json = JSON.parse(response.body)

    assert json['success']
    assert_empty json['stock']
    assert_not_requested levels
  end

  test 'live_stock requires the stock_withdrawals permission' do
    profile = Profile.create!(name: 'Sem Live')
    user = User.create!(name: 'Sem Live', email: 'sem_live@example.com', password: 'password123')
    user.profiles << profile
    levels = stub_levels_only('111' => { '9001' => 10 })
    sign_in user

    get live_stock_stock_withdrawals_path, params: { product_ids: [@a.id], location_ids: [@lagoa.id] }

    assert_redirected_to root_path
    assert_not_requested levels
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
end
