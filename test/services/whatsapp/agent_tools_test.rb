require 'test_helper'
require 'webmock/minitest'
require_relative '../../support/whatsapp_factory'
class WhatsappAgentToolsTest < ActiveSupport::TestCase
  include WhatsappFactory
  self.fixture_table_names = []
  setup do
    setup_whatsapp
    @automation = @a.automations.create!(name: 'Resposta automática', enabled: true)
    Location.where(slug: %w[bh_shopping log+]).delete_all
    Location.create!(slug: 'bh_shopping', name: 'BH Shopping', shopify_location_id: '111')
    Location.create!(slug: 'log+', name: 'Correios Log +', shopify_location_id: '222')
    Product.where(sku: %w[LEG-T1-P LEG-T1-M TOP-T1-M]).delete_all
    Product.create!(sku: 'LEG-T1-P', shopify_product_name: 'Legging Testeira Seamless Valência', option1: 'P', shopify_inventory_item_id: '901')
    Product.create!(sku: 'LEG-T1-M', shopify_product_name: 'Legging Testeira Seamless Valência', option1: 'M', shopify_inventory_item_id: '902')
    Product.create!(sku: 'TOP-T1-M', shopify_product_name: 'Top Testeira Seamless Valência', option1: 'M', shopify_inventory_item_id: '903')
  end

  def level(location_id, name, qty) = { 'location' => { 'id' => "gid://shopify/Location/#{location_id}", 'name' => name, 'isActive' => true }, 'quantities' => [{ 'quantity' => qty }] }

  def stock_graphql
    lambda do |_query, variables|
      nodes = variables[:ids].map do |gid|
        levels = case gid.split('/').last
                 when '901' then [level(111, 'BH Shopping', 0), level(222, 'Correios Log +', 3)]
                 when '902' then [level(111, 'BH Shopping', 2), level(222, 'Correios Log +', 1)]
                 else [level(111, 'BH Shopping', 0)]
                 end
        { 'id' => gid, 'inventoryLevels' => { 'nodes' => levels } }
      end
      { 'data' => { 'nodes' => nodes } }
    end
  end

  test 'stock lookup says which stores have the product and sizes, skipping a word that does not match' do
    tools = Whatsapp::AgentTools.new(%w[stock_lookup], [], graphql: stock_graphql)
    result = tools.call('consultar_estoque', { 'produto' => 'legging testeira valência preta' }.to_json)
    product = result[:produtos].sole
    assert_equal 'Legging Testeira Seamless Valência', product[:nome]
    stores = product[:disponivel_em].to_h { |d| [d[:loja], d[:tamanhos].sort] }
    assert_equal({ 'BH Shopping' => %w[M], 'Site (envio para casa)' => %w[M P] }, stores)

    sized = tools.call('consultar_estoque', { 'produto' => 'legging testeira', 'tamanho' => 'p' })
    assert_equal [{ loja: 'Site (envio para casa)', tamanhos: %w[P] }], sized[:produtos].sole[:disponivel_em]

    top = tools.call('consultar_estoque', { 'produto' => 'top testeira' })
    assert top[:produtos].sole[:sem_estoque_em_lugar_nenhum]
    assert_equal 3, tools.used.size
  end

  test 'order lookup only runs with an e-mail the customer wrote, and filters by number' do
    seen = []
    graphql = lambda do |_query, variables|
      seen << variables[:q]
      { 'data' => { 'orders' => { 'nodes' => [
        { 'name' => '#5001', 'createdAt' => '2026-10-30T12:00:00Z', 'email' => 'maria@example.com', 'displayFinancialStatus' => 'PAID',
          'displayFulfillmentStatus' => 'FULFILLED', 'totalPriceSet' => { 'shopMoney' => { 'amount' => '299.90' } },
          'lineItems' => { 'nodes' => [{ 'name' => 'Legging Valência - M', 'quantity' => 1 }] },
          'fulfillments' => [{ 'displayStatus' => 'IN_TRANSIT', 'trackingInfo' => [{ 'number' => 'AA123BR', 'url' => 'https://rastreio.test/AA123BR', 'company' => 'Correios' }] }] },
        { 'name' => '#4990', 'createdAt' => '2026-10-01T12:00:00Z', 'email' => 'maria@example.com', 'displayFinancialStatus' => 'PENDING',
          'displayFulfillmentStatus' => 'UNFULFILLED', 'lineItems' => { 'nodes' => [] }, 'fulfillments' => [] }
      ] } } }
    end
    history = [{ from: 'cliente', text: 'Oi, cadê meu pedido?' }, { from: 'loja', text: 'Qual o e-mail?' }, { from: 'cliente', text: 'É Maria@Example.com' }]
    tools = Whatsapp::AgentTools.new(%w[order_lookup], history, graphql: graphql)

    refused = Whatsapp::AgentTools.new(%w[order_lookup], history.first(2), graphql: graphql).call('buscar_pedidos', { 'email' => 'maria@example.com' })
    assert_match(/ainda não escreveu/, refused[:erro])
    assert_empty seen

    result = tools.call('buscar_pedidos', { 'email' => 'maria@example.com' })
    assert_equal ['email:maria@example.com'], seen
    assert_equal %w[#5001 #4990], result[:pedidos].map { |o| o[:numero] }
    first = result[:pedidos].first
    assert_equal 'pago', first[:pagamento]
    assert_equal 'enviado', first[:envio]
    assert_equal [{ situacao: 'em trânsito', codigo: 'AA123BR', link: 'https://rastreio.test/AA123BR', transportadora: 'Correios' }], first[:rastreio]

    assert_equal %w[#4990], tools.call('buscar_pedidos', { 'email' => 'maria@example.com', 'numero' => '4990' })[:pedidos].map { |o| o[:numero] }
  end

  test 'agent calls a tool, reads the result and then answers; disabled capabilities stay out of real conversations' do
    ENV['OPENAI_API_KEY'] = 'test-key'
    bodies = []
    replies = [
      { 'tool_calls' => [{ 'id' => 'call_1', 'type' => 'function', 'function' => { 'name' => 'consultar_estoque', 'arguments' => { produto: 'legging testeira', tamanho: 'M' }.to_json } }] },
      { 'content' => { action: 'reply', reply: 'Tem no BH Shopping e no site!', reason: 'estoque' }.to_json }
    ]
    stub_request(:post, Whatsapp::Agent::ENDPOINT).to_return do |req|
      bodies << JSON.parse(req.body)
      { status: 200, body: { choices: [{ message: replies.shift }] }.to_json, headers: { 'Content-Type' => 'application/json' } }
    end

    agent = Whatsapp::Agent.new(@automation, capabilities: @automation.capability_list, graphql: stock_graphql)
    decision = agent.decide([{ from: 'cliente', text: 'Tem a legging testeira M?', at: Time.current }])
    assert_equal 'Tem no BH Shopping e no site!', decision.reply
    assert_equal 'consultar_estoque', decision.tools.sole[:name]
    assert_equal %w[buscar_pedidos consultar_estoque], bodies.first['tools'].map { |t| t.dig('function', 'name') }.sort
    tool_message = bodies.last['messages'].find { |m| m['role'] == 'tool' }
    assert_includes tool_message['content'], 'BH Shopping'

    assert_nil Whatsapp::Agent.new(@automation).send(:system_prompt)[/FUNCIONALIDADES/]
    @automation.capability('order_lookup').update!(enabled: true)
    prompt = Whatsapp::Agent.new(@automation.reload).system_prompt
    assert_includes prompt, 'USE A FERRAMENTA buscar_pedidos'
    refute_includes prompt, 'consultar_estoque'
  ensure
    ENV.delete('OPENAI_API_KEY')
  end
end
