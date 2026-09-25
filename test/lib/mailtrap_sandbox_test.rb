require 'test_helper'
require 'webmock/minitest'
require 'minitest/mock'

class MailtrapSandboxTest < ActiveSupport::TestCase
  test 'builds SMTP settings from the first Mailtrap inbox' do
    stub_request(:get, 'https://mailtrap.io/api/v1/inboxes.json')
      .with(headers: { 'Authorization' => 'Bearer tok' })
      .to_return(body: [{ username: 'u1', password: 'p1', domain: 'sandbox.smtp.mailtrap.io', smtp_ports: [2525, 587] }].to_json)

    assert_equal({ user_name: 'u1', password: 'p1', address: 'sandbox.smtp.mailtrap.io', domain: 'sandbox.smtp.mailtrap.io',
                   port: 2525, authentication: :plain }, MailtrapSandbox.smtp_settings('tok'))
  end

  test 'raises when there is no inbox' do
    stub_request(:get, 'https://mailtrap.io/api/v1/inboxes.json').to_return(body: '[]')
    assert_raises(RuntimeError) { MailtrapSandbox.smtp_settings('tok') }
  end

  test 'never waits long for the Mailtrap API during boot' do
    captured = nil
    fake = lambda do |**args|
      captured = args
      Struct.new(:body).new([{ username: 'u', password: 'p', domain: 'd', smtp_ports: [2525] }].to_json)
    end
    RestClient::Request.stub(:execute, fake) { MailtrapSandbox.smtp_settings('tok') }
    assert_equal 5, captured[:timeout]
    assert_equal 'Bearer tok', captured[:headers][:Authorization]
  end
end
