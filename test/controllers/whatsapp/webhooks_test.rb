require 'test_helper'
require_relative '../../support/whatsapp_factory'
class WhatsappWebhooksTest < ActionDispatch::IntegrationTest
  include WhatsappFactory
  self.fixture_table_names = []
  setup { setup_whatsapp }
  def send_webhook(connection: @a, body: nil, token: @a.webhook_token)
    body ||= { event: 'messages.upsert', instance: connection.instance_key, data: wa_message('webhook'), date_time: Time.current.iso8601 }
    post "/whatsapp/webhooks/#{connection.instance_key}", params: body, headers: { 'X-Honey-Webhook-Token' => token }, as: :json
  end

  test 'provider webhook accepts the right token without a browser session' do
    send_webhook
    assert_response :accepted
    event = @a.events.last
    Whatsapp::EventJob.perform_now(event.id)
    assert_equal 1, @a.messages.where(provider_id: 'webhook').count
  end

  test 'empty webhook is rejected without creating an event' do
    post "/whatsapp/webhooks/#{@a.instance_key}", params: '', headers: { 'X-Honey-Webhook-Token' => @a.webhook_token, 'CONTENT_TYPE' => 'application/json' }
    assert_response :bad_request
    assert_empty @a.events
  end

  test 'missing invalid and other-number tokens are denied' do
    ['', 'x' * 64, @b.webhook_token].each { |token| send_webhook(token: token); assert_response :unauthorized }
    assert_equal 0, @a.events.count
  end

  test 'logical instance cannot be forged with a valid token' do
    send_webhook(body: { event: 'messages.upsert', instance: @b.instance_key, data: wa_message('wrong') })
    assert_response :unprocessable_entity
    send_webhook(body: { event: 'connection.update', instance: @a.instance_key, data: { instance: @b.instance_key, state: 'open' } })
    assert_response :unprocessable_entity
  end

  test 'repeated callbacks are idempotent and credentials are discarded' do
    body = { event: 'messages.upsert', instance: @a.instance_key, data: wa_message('same'), date_time: Time.current.iso8601, apikey: 'never-save-this' }
    2.times { send_webhook(body: body); assert_response :accepted }
    assert_equal 1, @a.events.count
    assert_not_includes @a.events.last.payload, 'never-save-this'
  end
end
