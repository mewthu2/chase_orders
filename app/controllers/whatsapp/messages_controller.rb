module Whatsapp
  class MessagesController < BaseController
    before_action :require_attendance
    before_action :set_conversation
    def index
      scope = @conversation.messages
      if params[:after_id].present?
        fresh = scope.where('id > ?', params[:after_id].to_i).order(:id).limit(100).to_a
        known = scope.where(id: Array(params[:ids]).first(200)).to_a
        rows = (fresh + known).uniq(&:id)
        render json: { messages: rows.map { |m| payload(m) }, after_id: fresh.last&.id || params[:after_id].to_i, more_new: fresh.length == 100 }
      else
        if params[:before].present?
          cursor = JSON.parse(Base64.urlsafe_decode64(params[:before].to_s))
          unless cursor.is_a?(Array) && cursor.length == 2 && cursor[0].is_a?(String) && cursor[1].is_a?(Integer) && cursor[1].positive?
            raise ArgumentError, 'Página de histórico inválida.'
          end
          time, id = cursor
          scope = scope.where('sent_at < ? OR (sent_at = ? AND id < ?)', Time.iso8601(time), Time.iso8601(time), id)
        end
        rows = scope.order(sent_at: :desc, id: :desc).limit(51).to_a
        page = rows.first(50)
        oldest = page.last
        render json: { messages: page.reverse.map { |m| payload(m) }, after_id: page.map(&:id).max || 0,
          before: rows.length > 50 ? Base64.urlsafe_encode64([oldest.sent_at.iso8601(6), oldest.id].to_json) : nil }
      end
    end

    def create
      nonce = params.require(:client_nonce).to_s
      raise ArgumentError, 'Identificador de envio inválido.' unless nonce.match?(/\A[a-zA-Z0-9-]{16,64}\z/)
      message = nil
      @conversation.connection.with_lock do
        message = @conversation.connection.messages.find_by(client_nonce: nonce)
        if message
          raise ArgumentError, 'Identificador usado em outra conversa.' unless message.conversation_id == @conversation.id
        else
          body = params[:body].to_s
          upload = params[:file]
          raise ArgumentError, 'Escreva uma mensagem ou selecione um arquivo.' if body.blank? && upload.blank?
          raise ArgumentError, 'A mensagem deve ter até 10.000 caracteres.' if body.length > 10_000
          raise ArgumentError, 'Este número precisa ser conectado antes do envio.' unless @conversation.connection.connected?
          if upload
            _, kind = Media.inspect_upload(upload.tempfile, filename: upload.original_filename)
            if kind == 'audio' && body.present?
              raise ArgumentError, 'Áudios não aceitam legenda. Envie o texto em uma mensagem separada.'
            end
          end
          message = @conversation.messages.create!(connection: @conversation.connection, user: current_user, client_nonce: nonce,
            body: body, direction: 'outgoing', state: 'queued', sent_at: Time.current)
          Media.store!(message, upload.tempfile, filename: upload.original_filename) if upload
          @conversation.update!(last_message_at: message.sent_at, last_message_preview: message.preview.truncate(180), state: 'open')
        end
      end
      SendJob.perform_later(message.id) if message.state == 'queued'
      render json: payload(message), status: :accepted
    end

    def retry_send
      message = @conversation.messages.find(params[:id])
      @conversation.connection.with_lock do
        message.reload
        raise ArgumentError, 'Somente uma falha confirmada antes do envio pode ser repetida.' unless message.state == 'failed'
        message.update!(state: 'queued', error_code: nil)
      end
      SendJob.perform_later(message.id)
      render json: payload(message), status: :accepted
    end

    def attachment
      message = @conversation.messages.find(params[:id])
      media = message.media || raise(ActiveRecord::RecordNotFound)
      # Private route, authorized on every request. No blob IDs or remote URLs leave the server.
      send_data media.download, type: media.content_type, filename: media.filename,
        disposition: %w[image audio].include?(message.kind) ? 'inline' : 'attachment'
    end

    private
    def set_conversation = @conversation = authorized_conversations.find(params[:conversation_id])
    def payload(message)
      message.slice(:id, :body, :kind, :direction, :state, :sent_at, :media_state, :client_nonce).merge(
        author: message.user&.name, media_url: message.media ? attachment_whatsapp_conversation_message_path(@conversation, message) : nil,
        filename: message.media&.filename)
    end
  end
end
