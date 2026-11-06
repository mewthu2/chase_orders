require 'stringio'
require 'base64'
module Whatsapp
  # Uses private storage directly: no public ActiveStorage blob/signed-ID routes.
  class Media < ApplicationRecord
    self.table_name = 'whatsapp_media'
    belongs_to :message
    MAX_BYTES = 10.megabytes
    TYPES = {
      'image/jpeg' => 'image', 'image/png' => 'image', 'image/webp' => 'image',
      'application/pdf' => 'document', 'text/plain' => 'document',
      'audio/mpeg' => 'audio', 'audio/ogg' => 'audio', 'audio/x-wav' => 'audio', 'audio/wav' => 'audio',
      'audio/mp4' => 'audio', 'audio/webm' => 'audio', 'video/webm' => 'audio', 'video/mp4' => 'video',
      'video/quicktime' => 'video', 'video/3gpp' => 'video'
    }.freeze
    AUDIO_EXTENSIONS = %w[.m4a .mp3 .ogg .oga .opus .wav .webm].freeze
    class Invalid < StandardError; end

    def self.inspect_upload(io, filename:)
      raise Invalid, 'O arquivo deve ter até 10 MB.' if io.size > MAX_BYTES || io.size.zero?
      io.rewind
      type = Marcel::MimeType.for(io)
      io.rewind
      if type == 'application/octet-stream' && File.extname(filename.to_s).downcase == '.txt'
        text = io.read.force_encoding(Encoding::UTF_8)
        type = 'text/plain' if text.valid_encoding? && !text.match?(/[\x00-\x08\x0b\x0c\x0e-\x1f]/) && !text.lstrip.start_with?('<')
        io.rewind
      end
      raise Invalid, 'Formato não permitido. Use JPG, PNG, WEBP, PDF, TXT, áudio ou vídeo.' unless TYPES.key?(type)
      kind = TYPES.fetch(type)
      # Contêiner MP4 também guarda só áudio (.m4a): a extensão desempata.
      kind = 'audio' if kind == 'video' && AUDIO_EXTENSIONS.include?(File.extname(filename.to_s).downcase)
      [type, kind, File.basename(filename.to_s).gsub(/[\x00-\x1f]/, '').truncate(150).presence || 'arquivo']
    end

    def self.store!(message, io, filename:)
      type, kind, safe_name = inspect_upload(io, filename: filename)
      # O WhatsApp já disse se é áudio ou vídeo; o arquivo baixado não traz nome confiável.
      kind = message.kind if %w[audio video].include?(kind) && %w[audio video].include?(message.kind)
      service_name = ENV['WHATSAPP_STORAGE_SERVICE'].presence || Rails.application.config.active_storage.service.to_s
      service = ActiveStorage::Blob.services.fetch(service_name)
      key = "whatsapp/#{SecureRandom.hex(32)}"
      record = new(message: message, storage_key: key, service_name: service_name, filename: safe_name,
        content_type: type, byte_size: io.size)
      begin
        service.upload(key, io, content_type: type)
        record.save!
        message.update!(kind: kind, media_state: 'ready')
      rescue StandardError
        service.delete(key)
        raise
      end
      record
    end

    def download = ActiveStorage::Blob.services.fetch(service_name).download(storage_key)
  end
end
