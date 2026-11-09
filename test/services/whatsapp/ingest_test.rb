require 'test_helper'
require 'minitest/mock'
require_relative '../../support/whatsapp_factory'
class WhatsappIngestTest < ActiveSupport::TestCase
  include WhatsappFactory
  include ActiveJob::TestHelper
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

  test 'webhook that lost the LID finds it in the provider and keeps one conversation' do
    lid = '281311918997594@lid'
    ingest = Whatsapp::Ingest.new(@a)
    old = ingest.message!(wa_message('history', jid: lid, at: 1.day.ago), historical: true)
    assert_not_equal @conversation.id, old.conversation_id
    @conversation.mark_read!(@agent, @message.id)
    payload = wa_message('live')
    payload['key'].merge!('remoteJidAlt' => @jid, 'addressingMode' => 'lid')
    gateway = Object.new
    calls = 0
    gateway.define_singleton_method(:find_message) do |id|
      calls += 1
      [{ 'key' => { 'id' => id, 'remoteJid' => lid, 'remoteJidAlt' => '5511988887777@s.whatsapp.net' } }]
    end
    @a.stub(:gateway, gateway) do
      live = ingest.message!(payload)
      assert_equal @conversation.id, live.conversation_id
      again = wa_message('live2')
      again['key'].merge!('remoteJidAlt' => @jid, 'addressingMode' => 'lid')
      ingest.message!(again)
    end
    assert_equal 1, calls, 'depois de ligar o LID não consulta de novo'
    assert_not Whatsapp::Conversation.exists?(old.conversation_id)
    assert_equal @conversation.id, old.reload.conversation_id
    assert_equal 4, @conversation.messages.count
    assert_equal %w[281311918997594@lid 5511988887777@s.whatsapp.net], @conversation.contact.aliases.pluck(:jid).sort
    assert_equal '5511988887777@s.whatsapp.net', @conversation.reload.contact.provider_jid
    assert_equal 1, @a.contacts.count
    assert_equal 2, @conversation.unread_count(@agent)
  end

  test 'provider down keeps the message and does not merge' do
    payload = wa_message('live')
    payload['key'].merge!('remoteJidAlt' => @jid, 'addressingMode' => 'lid')
    gateway = Object.new
    gateway.define_singleton_method(:find_message) { |_| raise Whatsapp::Providers::Evolution::Unavailable, 'provider_unavailable' }
    message = @a.stub(:gateway, gateway) { Whatsapp::Ingest.new(@a).message!(payload) }
    assert_equal @conversation.id, message.conversation_id
  end

  test 'sync re-reading a known message with LID and number joins the duplicate conversations' do
    lid = '123456789012345@lid'
    ingest = Whatsapp::Ingest.new(@a)
    other = ingest.message!(wa_message('from-lid', jid: lid, at: 1.minute.from_now)).conversation
    other.update!(assignee: @agent, stage: 'responding')
    record = wa_message('from-lid', jid: lid)
    record['key']['remoteJidAlt'] = @jid
    ingest.message!(record)
    assert_not Whatsapp::Conversation.exists?(other.id)
    conversation = @conversation.reload
    assert_equal 2, conversation.messages.count
    assert_equal @agent.id, conversation.assignee_id
    assert_equal 'responding', conversation.stage
    assert_equal '+5511988887777', conversation.contact.phone
  end

  test 'status broadcast and newsletters are ignored' do
    %w[status@broadcast 12345@newsletter].each do |jid|
      assert_nil Whatsapp::Ingest.new(@a).message!(wa_message('group', jid: jid))
    end
    assert_equal 1, @a.messages.count
  end

  test 'group import brings every group once, named, and later messages reuse it' do
    gateway = Object.new
    gateway.define_singleton_method(:groups) do
      [{ 'id' => '120363411839718288@g.us', 'subject' => 'MEGA LABS & CHASE', 'creation' => 1.week.ago.to_i },
       { 'id' => 'status@broadcast', 'subject' => 'x' }]
    end
    @a.stub(:gateway, gateway) do
      assert_equal 1, Whatsapp::GroupImport.call(@a)
      assert_equal 0, Whatsapp::GroupImport.call(@a)
      message = Whatsapp::Ingest.new(@a).message!(wa_message('g9', jid: '120363411839718288@g.us'))
      assert_equal 'MEGA LABS & CHASE', message.conversation.contact.name
    end
    assert_equal 1, @a.contacts.groups.count
    assert_equal 1, @a.conversations.where(contact_id: @a.contacts.groups.select(:id)).count
  end

  test 'group messages land in one group conversation with the sender and skip the queue and agent' do
    group = '120363401234567890@g.us'
    gateway = Object.new
    gateway.define_singleton_method(:group_subject) { |_jid| 'Revendedoras Chase' }
    first = second = nil
    @a.stub(:gateway, gateway) do
      payload = wa_message('g1', jid: group)
      payload['key']['participant'] = '5511977776666@s.whatsapp.net'
      first = Whatsapp::Ingest.new(@a).message!(payload)
      nameless = wa_message('g2', jid: group).merge('pushName' => nil)
      nameless['key']['participant'] = '123456789012345@lid'
      nameless['key']['participantAlt'] = '5511966665555@s.whatsapp.net'
      second = Whatsapp::Ingest.new(@a).message!(nameless)
    end
    assert_equal first.conversation_id, second.conversation_id
    contact = first.conversation.contact
    assert contact.group?
    assert_equal 'Revendedoras Chase', contact.display_name
    assert_nil contact.phone
    assert_equal 'Cliente Teste', first.sender_name
    assert_equal '+5511966665555', second.sender_name
    assert_equal '5511977776666@s.whatsapp.net', first.provider_key['participant']
    assert_equal 2, first.conversation.unread_count(@agent)
    assert_nil first.conversation.reload.agent_note
    assert_enqueued_jobs 0, only: Whatsapp::AgentJob
    # Contato do participante não vira conversa separada.
    assert_equal 1, @a.conversations.where.not(id: @conversation.id).count
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


  test 'reactions, albums and history notices do not become unsupported bubbles' do
    [{ 'reactionMessage' => { 'text' => '❤️', 'key' => { 'id' => 'x' } }, 'messageContextInfo' => {} },
     { 'albumMessage' => { 'expectedImageCount' => 2 } },
     { 'messageHistoryNotice' => {}, 'messageContextInfo' => {} }].each_with_index do |raw, i|
      payload = wa_message("silent-#{i}")
      payload['message'] = raw
      assert_nil Whatsapp::Ingest.new(@a).message!(payload)
    end
    assert_equal 1, @a.messages.count
  end

  test 'template, button, poll and location messages show their text' do
    {
      { 'templateMessage' => { 'interactiveMessageTemplate' => { 'body' => { 'text' => 'Seu cashback: R$ 10' } } } } => 'Seu cashback: R$ 10',
      { 'templateMessage' => { 'hydratedTemplate' => { 'hydratedContentText' => 'Pedido enviado' } } } => 'Pedido enviado',
      { 'buttonsResponseMessage' => { 'selectedDisplayText' => 'Sim' } } => 'Sim',
      { 'pollCreationMessageV3' => { 'name' => 'Cor?', 'options' => [{ 'optionName' => 'Azul' }] } } => "📊 Enquete: Cor?\n• Azul",
      { 'locationMessage' => { 'degreesLatitude' => -19.9, 'degreesLongitude' => -43.9 } } => '📍 Localização: https://maps.google.com/?q=-19.9,-43.9'
    }.each_with_index do |(raw, text), i|
      payload = wa_message("rich-#{i}")
      payload['message'] = { 'messageContextInfo' => {} }.merge(raw)
      message = Whatsapp::Ingest.new(@a).message!(payload)
      assert_equal ['text', text], [message.kind, message.body]
    end
    payload = wa_message('odd')
    payload['message'] = { 'someFutureMessage' => {} }
    assert_equal 'unsupported', Whatsapp::Ingest.new(@a).message!(payload).kind
  end

  test 'videos, video notes and stickers arrive as viewable media' do
    { 'videoMessage' => 'video', 'ptvMessage' => 'video', 'stickerMessage' => 'image' }.each do |field, kind|
      payload = wa_message("media-#{field}")
      payload['message'] = { field => { 'mimetype' => 'video/mp4', 'fileLength' => 1000 } }
      message = Whatsapp::Ingest.new(@a).message!(payload)
      assert_equal kind, message.kind
      assert_equal 'pending', message.media_state
    end
  end

  test 'mp4 container keeps the kind WhatsApp reported and uses extension for uploads' do
    mp4 = "\x00\x00\x00\x18ftypmp42\x00\x00\x00\x00mp42isom".b + ("\x00" * 64).b
    assert_equal 'video', Whatsapp::Media.inspect_upload(StringIO.new(mp4), filename: 'clip.mp4')[1]
    assert_equal 'audio', Whatsapp::Media.inspect_upload(StringIO.new(mp4), filename: 'voz.m4a')[1]
    @message.update!(kind: 'audio', media_state: 'pending')
    Whatsapp::Media.store!(@message, StringIO.new(mp4), filename: 'arquivo')
    assert_equal 'audio', @message.reload.kind
  end
end
