require 'test_helper'
require 'minitest/mock'
require_relative '../../support/whatsapp_factory'
class WhatsappMessageEditTest < ActionDispatch::IntegrationTest
  include WhatsappFactory
  self.fixture_table_names = []
  setup do
    setup_whatsapp
    sign_in @agent
    @mine = wa_outgoing(state: 'delivered')
    @mine.update!(provider_id: 'sent-1', provider_key: { 'id' => 'sent-1', 'remoteJid' => @jid, 'fromMe' => true })
    @calls = []
    calls = @calls
    @gateway = Object.new
    @gateway.define_singleton_method(:edit_message) { |m, text| calls << [:edit, m.id, text]; {} }
    @gateway.define_singleton_method(:delete_message) { |m| calls << [:delete, m.id]; {} }
  end

  def with_gateway(&block) = Whatsapp::Providers::Evolution.stub(:new, @gateway, &block)

  test 'author edits own text message within 15 minutes' do
    with_gateway { patch whatsapp_conversation_message_path(@conversation, @mine), params: { body: 'Resposta corrigida' }, as: :json }
    assert_response :success
    assert_equal [[:edit, @mine.id, 'Resposta corrigida']], @calls
    assert_equal 'Resposta corrigida', @mine.reload.body
    assert @mine.edited?
    assert response.parsed_body['edited']
    assert_equal 'Resposta corrigida', @conversation.reload.last_message_preview
  end

  test 'edit is refused after 15 minutes, for other people and for customer messages' do
    @mine.update!(sent_at: 16.minutes.ago)
    with_gateway { patch whatsapp_conversation_message_path(@conversation, @mine), params: { body: 'Tarde' }, as: :json }
    assert_response :unprocessable_entity
    @mine.update!(sent_at: Time.current, user: @other)
    with_gateway { patch whatsapp_conversation_message_path(@conversation, @mine), params: { body: 'Alheia' }, as: :json }
    assert_response :unprocessable_entity
    with_gateway { patch whatsapp_conversation_message_path(@conversation, @message), params: { body: 'Do cliente' }, as: :json }
    assert_response :unprocessable_entity
    with_gateway { delete whatsapp_conversation_message_path(@conversation, @message), as: :json }
    assert_response :unprocessable_entity
    assert_empty @calls
    assert_equal 'Olá', @message.reload.body
  end

  test 'author deletes own message for everyone and the text stops being served' do
    with_gateway { delete whatsapp_conversation_message_path(@conversation, @mine), as: :json }
    assert_response :success
    assert_equal [[:delete, @mine.id]], @calls
    assert @mine.reload.deleted?
    assert response.parsed_body['deleted']
    assert_nil response.parsed_body['body']
    assert_not response.parsed_body['can_delete']
    assert_equal 'Mensagem apagada', @conversation.reload.last_message_preview
    get whatsapp_conversation_messages_path(@conversation, format: :json)
    row = response.parsed_body['messages'].find { |m| m['id'] == @mine.id }
    assert_nil row['body']
  end

  test 'provider failure keeps the message unchanged' do
    @gateway.define_singleton_method(:delete_message) { |_| raise Whatsapp::Providers::Evolution::Unavailable, 'provider_unavailable' }
    with_gateway { delete whatsapp_conversation_message_path(@conversation, @mine), as: :json }
    assert_response :unprocessable_entity
    assert_not @mine.reload.deleted?
  end

  test 'messages list tells which ones the current person may change' do
    get whatsapp_conversation_messages_path(@conversation, format: :json)
    rows = response.parsed_body['messages'].index_by { |m| m['id'] }
    assert rows[@mine.id]['can_edit']
    assert rows[@mine.id]['can_delete']
    assert_not rows[@message.id]['can_edit']
    assert_not rows[@message.id]['can_delete']
  end

  test 'edit and revoke protocol echoes never become new bubbles' do
    payload = wa_message('proto', from_me: true)
    payload['message'] = { 'protocolMessage' => { 'type' => 'REVOKE', 'key' => { 'id' => 'sent-1' } } }
    assert_nil Whatsapp::Ingest.new(@a).message!(payload)
    assert_equal 2, @conversation.messages.count
  end
end
