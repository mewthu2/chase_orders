require 'test_helper'
require_relative '../../support/whatsapp_factory'
class WhatsappAccessTest < ActionDispatch::IntegrationTest
  include WhatsappFactory
  include ActiveJob::TestHelper
  self.fixture_table_names = []
  setup { setup_whatsapp; sign_in @agent }

  test 'existing Honey session opens inbox but cannot administer connections' do
    get whatsapp_conversations_path
    assert_response :success
    assert_select '#wa-inbox'
    get whatsapp_connections_path
    assert_response :forbidden
  end

  test 'listing filtering direct history and attachment access are scoped by number' do
    other_message = Whatsapp::Ingest.new(@b).message!(wa_message('b'))
    get whatsapp_conversations_path(format: :json)
    assert_equal [@conversation.id], response.parsed_body['conversations'].map { |c| c['id'] }
    get whatsapp_conversations_path(format: :json), params: { connection_id: @b.id }
    assert_empty response.parsed_body['conversations']
    get whatsapp_conversation_path(other_message.conversation, format: :json)
    assert_response :not_found
    get whatsapp_conversation_messages_path(other_message.conversation, format: :json)
    assert_response :not_found
    get attachment_whatsapp_conversation_message_path(other_message.conversation, other_message)
    assert_response :not_found
  end

  test 'revoked membership blocks subsequent realtime polls and attachments' do
    Whatsapp::Media.store!(@message, StringIO.new("documento de teste\n"), filename: 'teste.txt')
    get attachment_whatsapp_conversation_message_path(@conversation, @message)
    assert_response :success
    assert_match(/no-store/, response.headers['Cache-Control'])
    @a.memberships.where(user: @agent).delete_all
    get whatsapp_conversation_messages_path(@conversation, format: :json), params: { after_id: 0 }
    assert_response :not_found
    get attachment_whatsapp_conversation_message_path(@conversation, @message)
    assert_response :not_found
  end

  test 'new conversation requires explicit authorized company number' do
    post whatsapp_conversations_path, params: { phone: '+5511988887777' }, as: :json
    assert_response :unprocessable_entity
    post whatsapp_conversations_path, params: { connection_id: @b.id, phone: '+5511988887777' }, as: :json
    assert_response :not_found
    post whatsapp_conversations_path, params: { connection_id: @a.id, phone: '+5511988887777' }, as: :json
    assert_response :created
    assert_equal @conversation.id, response.parsed_body['id']
  end

  test 'repeating the browser submit does not duplicate the outbox' do
    body = { client_nonce: SecureRandom.uuid, body: 'Pedido recebido' }
    assert_difference 'Whatsapp::Message.count', 1 do
      2.times { post whatsapp_conversation_messages_path(@conversation), params: body, as: :json; assert_response :accepted }
    end
    assert_equal @a.id, Whatsapp::Message.last.connection_id
    assert_equal @agent.id, Whatsapp::Message.last.user_id
  end

  test 'JSON mutations enforce CSRF' do
    old = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    assert_no_difference 'Whatsapp::Message.count' do
      post whatsapp_conversation_messages_path(@conversation), params: { body: 'Não enviar', client_nonce: SecureRandom.uuid }, as: :json
      assert_response :unprocessable_entity
    end
  ensure
    ActionController::Base.allow_forgery_protection = old
  end

  test 'audio captions are rejected before enqueue so typed text is never silently lost' do
    file = Tempfile.new(['audio', '.wav'])
    file.binmode
    file.write('RIFF' + [40].pack('V') + 'WAVEfmt ' + [16, 1, 1, 8000, 16000, 2, 16].pack('VvvVVvv') + 'data' + [4].pack('V') + "\x00" * 4)
    file.flush
    upload = Rack::Test::UploadedFile.new(file.path, 'audio/wav')
    assert_no_difference 'Whatsapp::Message.count' do
      post whatsapp_conversation_messages_path(@conversation), params: { client_nonce: SecureRandom.uuid, body: 'Não perder este texto', file: upload }
      assert_response :unprocessable_entity
      assert_includes response.parsed_body['error'], 'Envie o texto em uma mensagem separada'
    end
  ensure
    file&.close!
  end

  test 'multipart attachment upload preserves fields and uses the selected number for both connections' do
    sign_out @agent
    sign_in @other
    [@a, @b].each do |connection|
      message = Whatsapp::Ingest.new(connection).message!(wa_message('upload-contact'))
      upload = Rack::Test::UploadedFile.new(Rails.root.join('test/fixtures/files/tiny.png'), 'image/png')
      nonce = SecureRandom.uuid
      post whatsapp_conversation_messages_path(message.conversation), params: { client_nonce: nonce, body: 'Confira esta imagem', file: upload }
      assert_response :accepted
      outgoing = connection.messages.find_by!(client_nonce: nonce)
      assert_equal 'Confira esta imagem', outgoing.body
      assert_equal 'image', outgoing.kind
      assert_equal 'ready', outgoing.media_state
      get attachment_whatsapp_conversation_message_path(message.conversation, outgoing)
      assert_response :success
      assert_equal File.binread(Rails.root.join('test/fixtures/files/tiny.png')), response.body.b
    end
  end

  test 'administrator can add a number using the browser form and assign attendants' do
    sign_out @agent
    sign_in @admin
    with_provider_env do
      post whatsapp_connections_path, params: { name: 'Loja nova', user_ids: [@agent.id] }
      assert_response :created
      connection = Whatsapp::Connection.find(response.parsed_body['id'])
      assert_equal 'Loja nova', connection.name
      assert_equal [@agent.id], connection.users.ids
      assert_equal 'connect', connection.control_action
      assert_nil connection.phone
      assert_nil connection.current_qr
    end
  end

  test 'assign transfer close reopen and read are shared across attendants' do
    patch whatsapp_conversation_path(@conversation), params: { operation: 'take' }, as: :json
    assert_equal @agent.id, @conversation.reload.assignee_id
    patch whatsapp_conversation_path(@conversation), params: { operation: 'transfer', assignee_id: @other.id }, as: :json
    assert_equal @other.id, @conversation.reload.assignee_id
    patch whatsapp_conversation_path(@conversation), params: { operation: 'close' }, as: :json
    assert_equal 'closed', @conversation.reload.state
    sign_out @agent
    sign_in @other
    get whatsapp_conversation_path(@conversation, format: :json)
    assert_equal @other.id, response.parsed_body['assignee_id']
    patch whatsapp_conversation_path(@conversation), params: { operation: 'reopen' }, as: :json
    assert_equal 'open', @conversation.reload.state
    assert_equal 4, @conversation.activities.count
  end

  test 'cannot transfer to a person without access to this number' do
    outsider = User.create!(name: 'Outro', email: 'outside@example.test', password: 'password123', profiles: [@profile], active: true)
    patch whatsapp_conversation_path(@conversation), params: { operation: 'transfer', assignee_id: outsider.id }, as: :json
    assert_response :unprocessable_entity
    assert_nil @conversation.reload.assignee_id
  end

  test 'uncertain messages cannot be retried through the API' do
    outgoing = wa_outgoing(state: 'uncertain')
    post retry_send_whatsapp_conversation_message_path(@conversation, outgoing), as: :json
    assert_response :unprocessable_entity
    assert_equal 'uncertain', outgoing.reload.state
  end

  test 'customers with matching numbers stay distinct until an explicit link' do
    first = Customer.create!(shopify_customer_id: 'wa-one', first_name: 'Ana', phone: '(11) 98888-7777')
    second = Customer.create!(shopify_customer_id: 'wa-two', first_name: 'Bia', phone: '+55 11 98888-7777')
    get customers_whatsapp_conversation_path(@conversation), as: :json
    assert_equal [first.id, second.id].sort, response.parsed_body['customers'].map { |c| c['id'] }.sort
    assert_nil @conversation.contact.reload.customer_id
    patch link_customer_whatsapp_conversation_path(@conversation), params: { customer_id: second.id }, as: :json
    assert_response :success
    assert_equal second.id, @conversation.contact.reload.customer_id
    assert_equal 2, Customer.where(shopify_customer_id: %w[wa-one wa-two]).count
  end

  test 'customer and order integration respects existing screen permissions' do
    @profile.screen_keys = ['whatsapp_attend']; @profile.save!
    get customers_whatsapp_conversation_path(@conversation), as: :json
    assert_response :forbidden
    get whatsapp_conversation_path(@conversation), as: :json
    assert_not response.parsed_body['can_link_customer']
    assert_nil response.parsed_body['orders_url']
  end

  test 'malformed history cursor is rejected without exposing other messages' do
    sign_in @agent
    [nil, {}, [nil, 1], ['2026-01-01', 'invalid']].each do |cursor|
      get whatsapp_conversation_messages_path(@conversation), params: { before: Base64.urlsafe_encode64(cursor.to_json) }, as: :json
      assert_response :unprocessable_entity
    end
  end

  test 'history pagination preserves chronological order and does not repeat page boundary' do
    55.times { |i| Whatsapp::Ingest.new(@a).message!(wa_message("history-#{i}", at: 2.hours.ago + i.seconds)) }
    get whatsapp_conversation_messages_path(@conversation), as: :json
    first = response.parsed_body
    assert_equal 50, first['messages'].size
    get whatsapp_conversation_messages_path(@conversation), params: { before: first['before'] }, as: :json
    second = response.parsed_body
    assert_empty first['messages'].map { |m| m['id'] } & second['messages'].map { |m| m['id'] }
    assert_equal 6, second['messages'].size
  end
  test 'authorized administrator sees connections but never credentials in HTML or JSON' do
    sign_out @agent
    sign_in @admin
    get whatsapp_connections_path
    assert_response :success
    assert_select '#wa-connections'
    get whatsapp_connections_path(format: :json)
    assert_response :success
    assert_not_includes response.body, @a.webhook_token
    assert_not_includes response.body, 'webhook_token'
    assert_not_includes response.body, 'apikey'
  end

  test 'order link filters the existing orders screen to the chosen customer' do
    customer = Customer.create!(shopify_customer_id: 'wa-orders-one', first_name: 'Ana')
    other = Customer.create!(shopify_customer_id: 'wa-orders-two', first_name: 'Bia')
    Order.create!(customer: customer, shopify_order_id: 'WA-OWN-ORDER')
    Order.create!(customer: other, shopify_order_id: 'WA-OTHER-ORDER')
    get orders_path, params: { customer_id: customer.id }
    assert_response :success
    assert_includes response.body, 'WA-OWN-ORDER'
    assert_not_includes response.body, 'WA-OTHER-ORDER'
  end

end
