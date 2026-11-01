require 'test_helper'
require 'webmock/minitest'
require_relative '../../support/whatsapp_factory'

class WhatsappConversationContextTest < ActionDispatch::IntegrationTest
  include WhatsappFactory
  self.fixture_table_names = []

  setup do
    setup_whatsapp
    sign_in @agent
    @previous_token = ENV['CHASE_ORDERS_TOKEN']
    ENV['CHASE_ORDERS_TOKEN'] = 'test-token'
    @customer = Customer.create!(shopify_customer_id: '123', first_name: 'Ana',
      email: 'ana@example.test', phone: '+55 11 98888-7777')
  end
  teardown { ENV['CHASE_ORDERS_TOKEN'] = @previous_token }

  test 'an unlinked contact has no orders and is never automatically linked' do
    get customer_context_whatsapp_conversation_path(@conversation), as: :json
    assert_response :success
    assert_nil response.parsed_body['customer']
    assert_empty response.parsed_body['orders']
    assert_nil @conversation.contact.reload.customer_id
    assert_not_requested :post, Whatsapp::ShopifyCustomerContext::ENDPOINT
  end

  test 'linked customer orders are queried live and scoped to the saved Shopify id' do
    @conversation.contact.update!(customer: @customer)
    request = stub_request(:post, Whatsapp::ShopifyCustomerContext::ENDPOINT).with do |request|
      JSON.parse(request.body)['variables'] == { 'id' => 'gid://shopify/Customer/123', 'after' => 'page-two' }
    end.to_return(body: { data: { customer: { id: 'gid://shopify/Customer/123', orders: {
      nodes: [], pageInfo: { hasNextPage: false, endCursor: nil }
    } } } }.to_json, headers: { 'Content-Type' => 'application/json' })
    get customer_context_whatsapp_conversation_path(@conversation), params: { after: 'page-two', customer_id: '999' }, as: :json
    assert_response :success
    assert_equal @customer.id, response.parsed_body.dig('customer', 'id')
    assert_equal 'ana@example.test', response.parsed_body.dig('customer', 'email')
    assert_match(/no-store/, response.headers['Cache-Control'])
    assert response.parsed_body['fetched_at'].present?
    assert_requested request
  end

  test 'provider failure is unavailable rather than an empty order history' do
    @conversation.contact.update!(customer: @customer)
    stub_request(:post, Whatsapp::ShopifyCustomerContext::ENDPOINT).to_return(status: 503)
    get customer_context_whatsapp_conversation_path(@conversation), as: :json
    assert_response :service_unavailable
    assert response.parsed_body['error'].present?
    assert_not response.parsed_body.key?('orders')
  end

  test 'customer context requires both existing screen permissions' do
    [%w[whatsapp_attend customers], %w[whatsapp_attend orders]].each do |screens|
      @profile.screen_keys = screens
      @profile.save!
      get customer_context_whatsapp_conversation_path(@conversation), as: :json
      assert_response :forbidden
      get whatsapp_conversation_path(@conversation), as: :json
      assert_not response.parsed_body['can_view_customer_context']
    end
    assert_not_requested :post, Whatsapp::ShopifyCustomerContext::ENDPOINT
  end

  test 'inactive users and users without attendance access cannot read context or write summaries' do
    @agent.update!(active: false)
    get customer_context_whatsapp_conversation_path(@conversation), as: :json
    assert_response :forbidden
    patch attendance_summary_whatsapp_conversation_path(@conversation), params: { body: 'Não salvar', version: 0 }, as: :json
    assert_response :forbidden

    @agent.update!(active: true)
    @profile.screen_keys = %w[customers orders]
    @profile.save!
    get customer_context_whatsapp_conversation_path(@conversation), as: :json
    assert_response :forbidden
    patch attendance_summary_whatsapp_conversation_path(@conversation), params: { body: 'Não salvar', version: 0 }, as: :json
    assert_response :forbidden
    assert_nil @conversation.reload.attendance_summary
  end

  test 'context and summaries require an authenticated session' do
    sign_out @agent
    get customer_context_whatsapp_conversation_path(@conversation), as: :json
    assert_response :unauthorized
    patch attendance_summary_whatsapp_conversation_path(@conversation), params: { body: 'Não salvar', version: 0 }, as: :json
    assert_response :unauthorized
    assert_nil @conversation.reload.attendance_summary
  end

  test 'summary context search and linking remain scoped to the accessible company number' do
    other_message = Whatsapp::Ingest.new(@b).message!(wa_message('other-number'))
    conversation = other_message.conversation
    get customer_context_whatsapp_conversation_path(conversation), as: :json
    assert_response :not_found
    get customers_whatsapp_conversation_path(conversation), as: :json
    assert_response :not_found
    patch link_customer_whatsapp_conversation_path(conversation), params: { customer_id: @customer.id }, as: :json
    assert_response :not_found
    patch attendance_summary_whatsapp_conversation_path(conversation), params: { body: 'Não salvar', version: 0 }, as: :json
    assert_response :not_found
    assert_nil conversation.reload.attendance_summary
    assert_nil conversation.contact.reload.customer_id
    assert_not_requested :post, Whatsapp::ShopifyCustomerContext::ENDPOINT
  end

  test 'revoked membership denies the new endpoints' do
    @a.memberships.where(user: @agent).delete_all
    get customer_context_whatsapp_conversation_path(@conversation), as: :json
    assert_response :not_found
    patch attendance_summary_whatsapp_conversation_path(@conversation), params: { body: 'Não salvar', version: 0 }, as: :json
    assert_response :not_found
  end

  test 'customer search supports email and treats SQL wildcard characters literally' do
    literal = Customer.create!(shopify_customer_id: '456', name: 'Cliente %_ especial', email: 'literal@example.test')
    get customers_whatsapp_conversation_path(@conversation), params: { q: 'ana@example.test' }, as: :json
    assert_response :success
    assert_equal [@customer.id], response.parsed_body['customers'].map { |c| c['id'] }
    get customers_whatsapp_conversation_path(@conversation), params: { q: '%_' }, as: :json
    assert_equal [literal.id], response.parsed_body['customers'].map { |c| c['id'] }
    get customers_whatsapp_conversation_path(@conversation), params: { q: "' OR 1=1 --" }, as: :json
    assert_empty response.parsed_body['customers']
    get customers_whatsapp_conversation_path(@conversation), params: { q: '11988887777' }, as: :json
    assert_equal [@customer.id], response.parsed_body['customers'].map { |c| c['id'] }
    assert_nil @conversation.contact.reload.customer_id
  end

  test 'summary is initially empty and saved with author date and version for another attendant' do
    get whatsapp_conversation_path(@conversation), as: :json
    assert_equal({ 'body' => '', 'version' => 0, 'updated_at' => nil, 'author_name' => nil }, response.parsed_body['attendance_summary'])
    assert_no_difference ['Whatsapp::Message.count', 'Whatsapp::Activity.count'] do
      patch attendance_summary_whatsapp_conversation_path(@conversation), params: { body: "Cliente pediu troca.\nAguardar foto 😊", version: 0 }, as: :json
    end
    assert_response :success
    saved = response.parsed_body['attendance_summary']
    assert_equal 1, saved['version']
    assert_equal @agent.name, saved['author_name']
    assert saved['updated_at'].present?
    sign_out @agent
    sign_in @other
    get whatsapp_conversation_path(@conversation), as: :json
    assert_equal saved, response.parsed_body['attendance_summary']
  end

  test 'concurrent stale edit returns saved summary without overwriting it' do
    @conversation.update_attendance_summary!(body: 'Resumo de Ana', version: 0, author: @agent)
    sign_out @agent
    sign_in @other
    patch attendance_summary_whatsapp_conversation_path(@conversation), params: { body: 'Rascunho de Bia', version: 0 }, as: :json
    assert_response :conflict
    assert_equal 'Resumo de Ana', response.parsed_body.dig('attendance_summary', 'body')
    assert_equal 'Resumo de Ana', @conversation.reload.attendance_summary
    assert_equal 1, @conversation.attendance_summary_version
    patch attendance_summary_whatsapp_conversation_path(@conversation), params: { body: 'Resumo revisado de Bia', version: 1 }, as: :json
    assert_response :success
    assert_equal @other.id, @conversation.reload.attendance_summary_author_id
    assert_equal 2, @conversation.attendance_summary_version
  end

  test 'new incoming messages do not create false summary conflicts' do
    @conversation.update_attendance_summary!(body: 'Aguardar resposta', version: 0, author: @agent)
    Whatsapp::Ingest.new(@a).message!(wa_message('next-message', text: 'Resposta'))
    patch attendance_summary_whatsapp_conversation_path(@conversation), params: { body: 'Cliente respondeu', version: 1 }, as: :json
    assert_response :success
    assert_equal 2, @conversation.reload.attendance_summary_version
  end

  test 'clearing a summary keeps attribution and advances the version' do
    @conversation.update_attendance_summary!(body: 'Resumo antigo', version: 0, author: @agent)
    patch attendance_summary_whatsapp_conversation_path(@conversation), params: { body: '', version: 1 }, as: :json
    assert_response :success
    assert_equal '', @conversation.reload.attendance_summary
    assert_equal 2, @conversation.attendance_summary_version
    assert_equal @agent.id, @conversation.attendance_summary_author_id
  end

  test 'invalid and oversized summaries do not change saved content' do
    [{ body: 'a' * 10_001, version: 0 }, { body: 'texto' }, { body: 'texto', version: 'invalid' },
      { body: ['texto'], version: 0 }, { body: 'texto', version: -1 }, { body: nil, version: 0 }].each do |params|
      patch attendance_summary_whatsapp_conversation_path(@conversation), params: params, as: :json
      assert_response :unprocessable_entity
      assert_equal 0, @conversation.reload.attendance_summary_version
      assert_nil @conversation.attendance_summary
    end
  end

  test 'summary changes enforce CSRF' do
    old = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    patch attendance_summary_whatsapp_conversation_path(@conversation), params: { body: 'Não salvar', version: 0 }, as: :json
    assert_response :unprocessable_entity
    assert_nil @conversation.reload.attendance_summary
  ensure
    ActionController::Base.allow_forgery_protection = old
  end
end
