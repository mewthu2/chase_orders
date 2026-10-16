module Whatsapp
  # Provider authentication replaces browser sessions/CSRF only on this endpoint.
  class WebhooksController < ActionController::API
    MAX_BYTES = 2.megabytes
    def create
      connection = Connection.find_by(instance_key: params[:instance_key])
      token = request.headers['X-Honey-Webhook-Token'].to_s
      return head :unauthorized unless connection && token.bytesize == 64 && ActiveSupport::SecurityUtils.secure_compare(token, connection.webhook_token)
      return head :payload_too_large if request.content_length.to_i > MAX_BYTES
      raw = request.body.read(MAX_BYTES + 1).to_s
      return head :payload_too_large if raw.bytesize > MAX_BYTES
      body = JSON.parse(raw)
      return head :unprocessable_entity unless body.is_a?(Hash) && body['instance'] == connection.instance_key
      kind = body['event'].to_s.downcase.tr('_', '.')
      return head :no_content unless Event::KINDS.include?(kind)
      data = body['data']
      return head :unprocessable_entity unless data.is_a?(Hash) || data.is_a?(Array)
      return head :payload_too_large if data.is_a?(Array) && data.size > 1000
      nested_instance = data.is_a?(Hash) ? (data['instance'] || data.dig('qrcode', 'instance')) : nil
      return head :unprocessable_entity if nested_instance && nested_instance != connection.instance_key
      at = body['date_time'].present? ? Time.iso8601(body['date_time']) : Time.current
      return head :unprocessable_entity if at > 5.minutes.from_now
      # Do not persist apikey, sender, server_url, headers or arbitrary top-level fields.
      Event.capture!(connection, kind, data, occurred_at: at)
      head :accepted
    rescue JSON::ParserError, ArgumentError
      head :bad_request
    end
  end
end
