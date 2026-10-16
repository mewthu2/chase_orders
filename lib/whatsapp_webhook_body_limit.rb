require 'stringio'
# Bound WhatsApp payloads before Rails parses or instruments JSON/multipart.
class WhatsappWebhookBodyLimit
  def initialize(app) = @app = app

  def call(env)
    path = env['PATH_INFO'].to_s
    return @app.call(env) unless path.start_with?('/whatsapp/') && %w[POST PUT PATCH].include?(env['REQUEST_METHOD'])
    limit = if path.start_with?('/whatsapp/webhooks/')
      2 * 1024 * 1024
    elsif path.match?(%r{\A/whatsapp/conversations/\d+/messages(?:\.json)?\z})
      11 * 1024 * 1024
    else
      64 * 1024
    end
    return too_large if env['CONTENT_LENGTH'].to_i > limit
    bytes = env['rack.input'].read(limit + 1).to_s
    return too_large if bytes.bytesize > limit
    env['rack.input'] = StringIO.new(bytes)
    env['CONTENT_LENGTH'] = bytes.bytesize.to_s
    @app.call(env)
  end

  private

  def too_large
    [413, { 'content-type' => 'application/json', 'cache-control' => 'no-store' }, ['{"error":"O conteúdo enviado ultrapassa o limite permitido."}']]
  end
end
