require 'test_helper'
require 'minitest/mock'
require_relative '../../support/whatsapp_factory'
class WhatsappJobsTest < ActiveSupport::TestCase
  include WhatsappFactory
  include ActiveJob::TestHelper
  self.fixture_table_names = []
  setup { setup_whatsapp }

  test 'sending then webhook echo persists one outgoing message and correct connection' do
    outgoing = wa_outgoing
    result = wa_message('sent-a', from_me: true, text: 'Resposta')
    gateway = Minitest::Mock.new
    gateway.expect(:send_message, result) { |m| m.id == outgoing.id && m.connection_id == @a.id }
    Whatsapp::Connection.stub(:find, @a) do
      Whatsapp::Message.stub(:find, outgoing) do
        outgoing.stub(:connection, @a) { @a.stub(:gateway, gateway) { Whatsapp::SendJob.perform_now(outgoing.id) } }
      end
    end
    Whatsapp::Ingest.new(@a).message!(result)
    assert_equal 'sent', outgoing.reload.state
    assert_equal 1, @a.messages.where(provider_id: 'sent-a').count
    assert_equal 0, @b.messages.count
    gateway.verify
  end

  test 'timeout has uncertain outcome and a second job never retries it' do
    outgoing = wa_outgoing
    gateway = Object.new
    calls = 0
    gateway.define_singleton_method(:send_message) { |_m| calls += 1; raise Whatsapp::Providers::Evolution::Unavailable, 'provider_unavailable' }
    Whatsapp::Message.stub(:find, outgoing) do
      outgoing.stub(:connection, @a) do
        @a.stub(:gateway, gateway) { 2.times { Whatsapp::SendJob.perform_now(outgoing.id) } }
      end
    end
    assert_equal 'uncertain', outgoing.reload.state
    assert_equal 'Resposta', outgoing.body
    assert_equal 1, calls
  end

  test 'revoking number access prevents queued sends' do
    outgoing = wa_outgoing
    @a.memberships.where(user: @agent).delete_all
    Whatsapp::SendJob.perform_now(outgoing.id)
    assert_equal 'failed', outgoing.reload.state
    assert_nil outgoing.provider_id
  end

  test 'disconnected connection fails safely before transmission' do
    outgoing = wa_outgoing
    @a.update!(enabled: false)
    Whatsapp::SendJob.perform_now(outgoing.id)
    assert_equal 'failed', outgoing.reload.state
    assert_nil outgoing.attempted_at
  end

  test 'worker interruption is recovered without resending an uncertain message' do
    outgoing = wa_outgoing(state: 'sending')
    outgoing.update!(attempted_at: 5.minutes.ago)
    Whatsapp::Recovery.call
    assert_equal 'uncertain', outgoing.reload.state
    assert_empty enqueued_jobs.select { |j| j[:job] == Whatsapp::SendJob && j[:args] == [outgoing.id] }
  end

  test 'duplicate events processed after restart are harmless' do
    data = wa_message('restart')
    at = Time.current
    a = Whatsapp::Event.capture!(@a, 'messages.upsert', data, occurred_at: at)
    b = Whatsapp::Event.capture!(@a, 'messages.upsert', data, occurred_at: at)
    assert_equal a.id, b.id
    2.times { Whatsapp::EventJob.perform_now(a.id) }
    assert_equal 1, @a.messages.where(provider_id: 'restart').count
    assert a.reload.processed_at
  end

  test 'sync recovers stored messages with overlap without duplicating live events' do
    gateway = Object.new
    gateway.define_singleton_method(:state) { { 'state' => 'open' } }
    rows = [wa_message('message-1'), wa_message('recovered')]
    gateway.define_singleton_method(:history) { |**_| { 'records' => rows, 'pages' => 1 } }
    Whatsapp::Connection.stub(:find, @a) { @a.stub(:gateway, gateway) { 2.times { Whatsapp::SyncJob.perform_now(@a.id) } } }
    assert_equal 2, @a.messages.count
    assert @a.reload.last_synced_at
    assert_equal 0, @b.messages.count
  end
  test 'disconnect affects only its instance and preserves all history' do
    @a.update!(enabled: false, control_action: 'disconnect', control_version: 1)
    fake = Minitest::Mock.new
    fake.expect(:disconnect, { 'status' => 'SUCCESS' })
    Whatsapp::Connection.stub(:find, @a) { @a.stub(:gateway, fake) { Whatsapp::ControlJob.perform_now(@a.id, 1) } }
    assert_equal 'disconnected', @a.reload.state
    assert_equal 1, @a.messages.count
    assert_equal 'connected', @b.reload.state
    fake.verify
  end

  test 'stale control job cannot disconnect a newly requested session' do
    @a.update!(control_action: 'connect', control_version: 2)
    Whatsapp::ControlJob.perform_now(@a.id, 1)
    assert_equal 'connect', @a.reload.control_action
    assert_equal 'connected', @a.state
  end

  test 'reconnect uses restart and keeps the same independent instance' do
    @a.update!(control_action: 'reconnect', control_version: 3)
    fake = Minitest::Mock.new
    fake.expect(:ensure_instance, {})
    fake.expect(:reconnect, {})
    fake.expect(:state, { 'state' => 'open', 'wuid' => '551100000001@s.whatsapp.net' })
    key = @a.instance_key
    Whatsapp::Connection.stub(:find, @a) { @a.stub(:gateway, fake) { Whatsapp::ControlJob.perform_now(@a.id, 3) } }
    assert_equal key, @a.reload.instance_key
    assert_equal 'connected', @a.state
    assert_equal 1, @a.messages.count
    fake.verify
  end

  test 'provider-confirmed Brazilian phone normalization keeps the original conversation' do
    outgoing = wa_outgoing
    result = wa_message('normalized', jid: '551188887777@s.whatsapp.net', from_me: true, text: 'Resposta')
    gateway = Minitest::Mock.new
    gateway.expect(:send_message, result) { |m| m.id == outgoing.id }
    Whatsapp::Message.stub(:find, outgoing) do
      outgoing.stub(:connection, @a) { @a.stub(:gateway, gateway) { Whatsapp::SendJob.perform_now(outgoing.id) } }
    end
    assert_equal 'sent', outgoing.reload.state
    assert_equal @conversation.id, outgoing.conversation_id
    incoming = Whatsapp::Ingest.new(@a).message!(wa_message('normalized-reply', jid: '551188887777@s.whatsapp.net'))
    assert_equal @conversation.id, incoming.conversation_id
    assert_equal 1, @a.conversations.count
    gateway.verify
  end

end
