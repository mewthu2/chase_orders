require 'test_helper'
class WhatsappBodyLimitTest < ActiveSupport::TestCase
  self.fixture_table_names = []
  test 'oversize webhook is rejected before JSON parsing' do
    called = false
    app = WhatsappWebhookBodyLimit.new(->(_) { called = true; [200, {}, []] })
    result = app.call('PATH_INFO' => '/whatsapp/webhooks/honey-test', 'REQUEST_METHOD' => 'POST', 'CONTENT_LENGTH' => '3000000')
    assert_equal 413, result.first
    assert_not called
  end

  test 'chunked oversize uploads are bounded before multipart parsing' do
    called = false
    app = WhatsappWebhookBodyLimit.new(->(_) { called = true; [200, {}, []] })
    result = app.call('PATH_INFO' => '/whatsapp/conversations/1/messages', 'REQUEST_METHOD' => 'POST',
      'rack.input' => StringIO.new('a' * (11.megabytes + 1)))
    assert_equal 413, result.first
    assert_not called
  end

  test 'unrelated Honey routes are untouched' do
    app = WhatsappWebhookBodyLimit.new(->(_) { [204, {}, []] })
    assert_equal 204, app.call('PATH_INFO' => '/orders', 'REQUEST_METHOD' => 'POST').first
  end
end
