require 'test_helper'
require 'webmock/minitest'
require_relative '../../support/whatsapp_factory'
class WhatsappProviderTest < ActiveSupport::TestCase
  include WhatsappFactory
  self.fixture_table_names = []
  setup { setup_whatsapp }
  teardown { WebMock.reset! }

  test 'create uses stable Baileys contract and per-number authenticated webhooks' do
    with_provider_env do
      root = 'http://evolution.test:8080'
      stub_request(:get, "#{root}/instance/fetchInstances?instanceName=#{@a.instance_key}").to_return(status: 404, body: '{}')
      create = stub_request(:post, "#{root}/instance/create").with do |r|
        data = JSON.parse(r.body)
        data['integration'] == 'WHATSAPP-BAILEYS' && data['instanceName'] == @a.instance_key &&
          data.dig('webhook', 'headers', 'X-Honey-Webhook-Token') == @a.webhook_token && data['syncFullHistory'] == false
      end.to_return(status: 201, body: '{}')
      webhook = stub_request(:post, "#{root}/webhook/set/#{@a.instance_key}").to_return(status: 201, body: '{}')
      @a.gateway.ensure_instance
      assert_requested create
      assert_requested webhook
    end
  end

  test 'text is sent through the selected instance only' do
    with_provider_env do
      outgoing = wa_outgoing
      req = stub_request(:post, "http://evolution.test:8080/message/sendText/#{@a.instance_key}")
        .with(headers: { 'Apikey' => 'fake-key' }, body: { number: @jid, text: 'Resposta', linkPreview: false }.to_json)
        .to_return(status: 201, body: wa_message('sent', from_me: true).to_json)
      result = @a.gateway.send_message(outgoing)
      assert_equal 'sent', result.dig('key', 'id')
      assert_requested req, times: 1
    end
  end

  test 'send transport timeout makes exactly one HTTP attempt' do
    with_provider_env do
      req = stub_request(:post, "http://evolution.test:8080/message/sendText/#{@a.instance_key}").to_timeout
      assert_raises(Whatsapp::Providers::Evolution::Unavailable) { @a.gateway.send_message(wa_outgoing) }
      assert_requested req, times: 1
    end
  end

  test 'attachments validate actual bytes not client MIME or extension' do
    assert_raises(Whatsapp::Media::Invalid) { Whatsapp::Media.inspect_upload(StringIO.new('<html><script>alert(1)</script></html>'), filename: 'foto.png') }
    assert_raises(Whatsapp::Media::Invalid) { Whatsapp::Media.inspect_upload(StringIO.new('a' * (10.megabytes + 1)), filename: 'documento.txt') }
    assert_raises(Whatsapp::Media::Invalid) { Whatsapp::Media.inspect_upload(StringIO.new('<svg xmlns="http://www.w3.org/2000/svg"></svg>'), filename: 'arquivo.svg') }
  end

  test 'private media stores no ActiveStorage public blob' do
    assert_no_difference 'ActiveStorage::Blob.count' do
      Whatsapp::Media.store!(@message, StringIO.new("arquivo de teste\n"), filename: '../teste.txt')
    end
    media = @message.reload.media
    assert_equal 'teste.txt', media.filename
    assert_equal "arquivo de teste\n", media.download
  end

  test 'media fetch uses provider key not a client-controlled URL' do
    with_provider_env do
      req = stub_request(:post, "http://evolution.test:8080/chat/getBase64FromMediaMessage/#{@a.instance_key}")
        .with { |r| JSON.parse(r.body) == { 'message' => { 'key' => @message.provider_key }, 'convertToMp4' => false } }
        .to_return(status: 200, body: { base64: Base64.strict_encode64("Documento\n"), fileName: 'teste.txt' }.to_json)
      @message.update!(media_state: 'pending')
      Whatsapp::MediaJob.perform_now(@message.id)
      assert_equal 'ready', @message.reload.media_state
      assert_requested req
    end
  end

  test 'media retries have a durable budget and respect the next attempt time' do
    with_provider_env do
      req = stub_request(:post, "http://evolution.test:8080/chat/getBase64FromMediaMessage/#{@a.instance_key}").to_timeout
      @message.update!(media_state: 'pending')
      4.times do |attempt|
        Whatsapp::MediaJob.perform_now(@message.id)
        assert_equal attempt + 1, @message.reload.media_attempts
        if attempt < 3
          assert_equal 'pending', @message.media_state
          Whatsapp::MediaJob.perform_now(@message.id)
          assert_equal attempt + 1, @message.reload.media_attempts
          travel_to @message.media_retry_at + 1.second
        end
      end
      assert_equal 'unavailable', @message.reload.media_state
      Whatsapp::MediaJob.perform_now(@message.id)
      assert_requested req, times: 4
    ensure
      travel_back
    end
  end
  def sample_media
    { 'image' => [File.binread(Rails.root.join('test/fixtures/files/tiny.png')), 'foto.png'],
      'document' => ["%PDF-1.4\n%%EOF\n", 'pedido.pdf'],
      'audio' => ["RIFF" + [40].pack('V') + "WAVEfmt " + [16, 1, 1, 8000, 16000, 2, 16].pack('VvvVVvv') + "data" + [4].pack('V') + "\x00" * 4, 'audio.wav'] }
  end

  test 'image PDF and audio use matching media endpoints for both numbers' do
    with_provider_env do
      [@a, @b].each do |connection|
        contact = Whatsapp::Contact.resolve!(connection, { 'remoteJid' => @jid })
        conversation = connection.conversations.find_or_create_by!(contact: contact)
        sample_media.each do |kind, (bytes, filename)|
          message = conversation.messages.create!(connection: connection, user: @other, direction: 'outgoing', state: 'queued', sent_at: Time.current, body: 'Anexo')
          Whatsapp::Media.store!(message, StringIO.new(bytes), filename: filename)
          assert_equal kind, message.reload.kind
          endpoint = kind == 'audio' ? 'sendWhatsAppAudio' : 'sendMedia'
          req = stub_request(:post, "http://evolution.test:8080/message/#{endpoint}/#{connection.instance_key}").with do |request|
            data = JSON.parse(request.body)
            data['number'] == @jid && Base64.strict_decode64(data[kind == 'audio' ? 'audio' : 'media']) == bytes
          end.to_return(status: 201, body: wa_message("#{kind}-#{connection.id}", from_me: true).to_json)
          connection.gateway.send_message(message)
          assert_requested req, times: 1
        end
      end
    end
  end

  test 'incoming image PDF and audio fetch only their corresponding connection' do
    with_provider_env do
      [@a, @b].each do |connection|
        sample_media.each do |kind, (bytes, filename)|
          data = wa_message("#{kind}-receive")
          data['message'] = { "#{kind}Message" => { 'fileLength' => bytes.bytesize, 'fileName' => filename } }
          message = Whatsapp::Ingest.new(connection).message!(data)
          stub_request(:post, "http://evolution.test:8080/chat/getBase64FromMediaMessage/#{connection.instance_key}")
            .to_return(status: 200, body: { base64: Base64.strict_encode64(bytes), fileName: filename }.to_json)
          Whatsapp::MediaJob.perform_now(message.id)
          assert_equal 'ready', message.reload.media_state
          assert_equal kind, message.kind
          assert_equal bytes, message.media.download
        end
      end
    end
  end

end
