require 'test_helper'
require_relative '../../support/whatsapp_factory'
class WhatsappIngestTest < ActiveSupport::TestCase
  include WhatsappFactory
  self.fixture_table_names = []
  setup { setup_whatsapp }

  test 'two company numbers keep the same customer and provider ID isolated' do
    other = Whatsapp::Ingest.new(@b).message!(wa_message('message-1'))
    assert_not_equal @conversation.id, other.conversation_id
    assert_not_equal @message.id, other.id
    assert_equal 2, Whatsapp::Message.where(provider_id: 'message-1').count
    assert_equal 2, Whatsapp::Contact.where(connection_id: [@a.id, @b.id], phone: '+5511988887777').count
  end

  test 'duplicate and phone-sent echoes do not duplicate messages or unread counts' do
    3.times { Whatsapp::Ingest.new(@a).message!(wa_message('message-1')) }
    3.times { Whatsapp::Ingest.new(@a).message!(wa_message('phone-echo', from_me: true)) }
    assert_equal 2, @conversation.messages.count
    assert_equal 1, @conversation.unread_count(@agent)
    assert_equal 'outgoing', @a.messages.find_by(provider_id: 'phone-echo').direction
  end

  test 'receipts before the message are applied and never regress' do
    ingest = Whatsapp::Ingest.new(@a)
    ingest.receipt!({ 'keyId' => 'reply', 'status' => 'READ' })
    message = ingest.message!(wa_message('reply', from_me: true, status: 'SERVER_ACK'))
    assert_equal 'read', message.reload.state
    ingest.receipt!({ 'keyId' => 'reply', 'status' => 'DELIVERY_ACK' })
    assert_equal 'read', message.reload.state
  end

  test 'unknown statuses never imply delivered or read' do
    message = Whatsapp::Ingest.new(@a).message!(wa_message('reply', from_me: true, status: 'PENDING'))
    assert_equal 'sent', message.state
    assert_equal 1, message.receipt_rank
  end

  test 'LID is not a phone and confirmed alternate JID resolves existing contact' do
    ingest = Whatsapp::Ingest.new(@a)
    payload = wa_message('lid', jid: '123456789012345@lid')
    payload['key']['remoteJidAlt'] = @jid
    result = ingest.message!(payload)
    assert_equal @conversation.id, result.conversation_id
    assert_equal '+5511988887777', result.conversation.contact.phone
    unknown = ingest.message!(wa_message('lid2', jid: '333333333333333@lid'))
    assert_nil unknown.conversation.contact.phone
  end

  test 'groups broadcast and newsletters are ignored' do
    %w[12345@g.us status@broadcast 12345@newsletter].each do |jid|
      assert_nil Whatsapp::Ingest.new(@a).message!(wa_message('group', jid: jid))
    end
    assert_equal 1, @a.messages.count
  end

  test 'historical sync does not create unread counts or reopen an ended conversation' do
    @conversation.update!(state: 'closed')
    message = Whatsapp::Ingest.new(@a).message!(wa_message('old', at: 2.days.ago), historical: true)
    assert message.historical?
    assert_equal 1, @conversation.unread_count(@agent)
    assert_equal 'closed', @conversation.reload.state
    Whatsapp::Ingest.new(@a).message!(wa_message('new'))
    assert_equal 'open', @conversation.reload.state
  end

  test 'read cursor is per user and never decreases' do
    @conversation.mark_read!(@agent, @message.id)
    @conversation.mark_read!(@agent, 0)
    assert_equal 0, @conversation.unread_count(@agent)
    assert_equal 1, @conversation.unread_count(@other)
  end

  test 'QR expires and delayed connection events cannot revive revoked session' do
    @a.update!(state: 'connecting')
    at = Time.current
    ingest = Whatsapp::Ingest.new(@a)
    ingest.qr!({ 'base64' => 'data:image/png;base64,aGVsbG8=' }, occurred_at: at)
    assert @a.current_qr
    travel_to(at + 31.seconds) { assert_nil @a.current_qr }
    ingest.connection!({ 'state' => 'open', 'wuid' => '551100000001:12@s.whatsapp.net' }, occurred_at: at + 2.seconds)
    assert_equal 'connected', @a.state
    assert_equal '+551100000001', @a.phone
    assert_nil @a.current_qr
    ingest.connection!({ 'state' => 'close' }, occurred_at: at)
    assert_equal 'connected', @a.state
    @a.update!(enabled: false)
    ingest.connection!({ 'state' => 'open' }, occurred_at: at + 3.seconds)
    assert_equal 'disconnected', @a.state
    assert_equal 'connected', @b.reload.state
  end

  test 'credentials and QR are encrypted at rest' do
    assert_not_equal @a.webhook_token, @a.attributes_before_type_cast['webhook_token']
    assert_not_includes @a.attributes_before_type_cast['webhook_token'], @a.webhook_token
  end
  test 'provider IDs remain case sensitive and unique inside a connection' do
    ingest = Whatsapp::Ingest.new(@a)
    assert_not_equal ingest.message!(wa_message('ABC')).id, ingest.message!(wa_message('abc')).id
    assert_raises(ActiveRecord::RecordNotUnique) do
      @a.messages.create!(conversation: @conversation, provider_id: 'ABC', body: 'duplicate', state: 'received', direction: 'incoming', sent_at: Time.current)
    end
  end

  test 'refetching a cached QR never extends its expiration' do
    @a.update!(state: 'connecting')
    ingest = Whatsapp::Ingest.new(@a)
    data = { 'base64' => 'data:image/png;base64,aGVsbG8=' }
    at = Time.current
    ingest.qr!(data, occurred_at: at)
    ingest.qr!(data, occurred_at: at + 20.seconds)
    assert_in_delta (at + 30.seconds).to_f, @a.qr_expires_at.to_f, 0.001
  end

end
