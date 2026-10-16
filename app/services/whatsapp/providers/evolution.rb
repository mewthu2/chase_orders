require 'net/http'
require 'base64'

module Whatsapp
  module Providers
    # Contract pinned to Evolution API 2.3.7 (cd800f2976e1e5b682fbf86a01ee4d85ae61f370).
    # Never follow provider redirects or log response bodies, which can contain credentials.
    class Evolution
      class Error < StandardError; end
      class Unavailable < Error; end
      class Rejected < Error; end
      class NotConfigured < Error; end
      MAX_RESPONSE = 16.megabytes
      attr_reader :connection
      def initialize(connection) = @connection = connection

      def self.configured?
        %w[WHATSAPP_EVOLUTION_URL WHATSAPP_EVOLUTION_API_KEY WHATSAPP_WEBHOOK_BASE_URL].all? { |k| ENV[k].present? }
      end

      def ensure_instance
        existing = instances.find { |i| i['name'] == connection.instance_key }
        unless existing
          request(:post, '/instance/create', instanceName: connection.instance_key, integration: 'WHATSAPP-BAILEYS',
            qrcode: false, groupsIgnore: true, readMessages: false, readStatus: false, syncFullHistory: false,
            webhook: webhook_config)
        end
        request(:post, "/webhook/set/#{instance}", webhook: webhook_config)
      end
      def connect = request(:get, "/instance/connect/#{instance}")
      def reconnect
        state['state'] == 'close' ? connect : request(:post, "/instance/restart/#{instance}")
      end
      def disconnect = request(:delete, "/instance/logout/#{instance}")
      def state
        status = request(:get, "/instance/connectionState/#{instance}").dig('instance', 'state')
        raise Unavailable, 'unexpected_provider_state' unless %w[open close connecting].include?(status)
        info = instances.find { |i| i['name'] == connection.instance_key } || {}
        { 'state' => status, 'wuid' => info['ownerJid'] }
      end
      def instances
        request(:get, "/instance/fetchInstances?instanceName=#{instance}")
      rescue Rejected => e
        raise unless e.message == 'provider_http_404'
        []
      end

      def send_message(message)
        target = message.conversation.contact.provider_jid
        raise Rejected, 'invalid_recipient' unless Phone.individual_jid?(target)
        if message.kind == 'text'
          request(:post, "/message/sendText/#{instance}", number: target, text: message.body, linkPreview: false)
        else
          media = message.media
          raise Rejected, 'missing_media' unless media
          encoded = Base64.strict_encode64(media.download)
          if message.kind == 'audio'
            request(:post, "/message/sendWhatsAppAudio/#{instance}", number: target, audio: encoded, encoding: true)
          else
            request(:post, "/message/sendMedia/#{instance}", number: target, mediatype: message.kind,
              mimetype: media.content_type, fileName: media.filename, caption: message.body.to_s, media: encoded)
          end
        end
      end

      def media(message)
        request(:post, "/chat/getBase64FromMediaMessage/#{instance}", message: { key: message.provider_key }, convertToMp4: false)
      end

      def history(from:, to:, page: 1)
        request(:post, "/chat/findMessages/#{instance}", where: { messageTimestamp: { gte: from.iso8601, lte: to.iso8601 } }, page: page, offset: 100).fetch('messages')
      end

      def find_message(id)
        request(:post, "/chat/findMessages/#{instance}", where: { key: { id: id } }, page: 1, offset: 10).dig('messages', 'records') || []
      end

      private

      def instance = connection.instance_key
      def webhook_config
        base = ENV.fetch('WHATSAPP_WEBHOOK_BASE_URL', '').delete_suffix('/')
        raise NotConfigured, 'provider_not_configured' if base.blank?
        { enabled: true, url: "#{base}/whatsapp/webhooks/#{instance}", byEvents: false, base64: false,
          headers: { 'X-Honey-Webhook-Token' => connection.webhook_token },
          events: Event::KINDS.map { |e| e.tr('.', '_').upcase } }
      end

      def request(method, path, body = nil)
        raise NotConfigured, 'provider_not_configured' unless self.class.configured?
        base = URI(ENV.fetch('WHATSAPP_EVOLUTION_URL').delete_suffix('/'))
        raise NotConfigured, 'invalid_provider_url' unless %w[http https].include?(base.scheme) && base.host && !base.userinfo && base.path.to_s.empty?
        uri = URI("#{base}#{path}")
        klass = { get: Net::HTTP::Get, post: Net::HTTP::Post, delete: Net::HTTP::Delete }.fetch(method)
        req = klass.new(uri)
        req['apikey'] = ENV.fetch('WHATSAPP_EVOLUTION_API_KEY')
        req['Content-Type'] = 'application/json'
        req.body = body.to_json if body
        response_body = +''
        code = nil
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 5, read_timeout: 35, write_timeout: 20, max_retries: 0) do |http|
          http.request(req) do |res|
            code = res.code.to_i
            res.read_body do |chunk|
              response_body << chunk
              raise Unavailable, 'provider_response_too_large' if response_body.bytesize > MAX_RESPONSE
            end
          end
        end
        raise Rejected, "provider_http_#{code}" if (400..499).cover?(code)
        raise Unavailable, "provider_http_#{code}" unless (200..299).cover?(code)
        parsed = JSON.parse(response_body.presence || '{}')
        raise Unavailable, 'provider_operation_failed' if parsed.is_a?(Hash) && parsed['error'] == true
        parsed
      rescue JSON::ParserError, IOError, SystemCallError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError
        raise Unavailable, 'provider_unavailable'
      end
    end
  end
end
