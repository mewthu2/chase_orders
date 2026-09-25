# Prints e PDFs anexados na abertura do chamado e nas interações (Active Storage → Bucketeer).
module HasTicketAttachments
  extend ActiveSupport::Concern

  ALLOWED_CONTENT_TYPES = %w[image/png image/jpeg image/gif image/webp application/pdf].freeze
  MAX_FILE_SIZE = 10.megabytes
  MAX_FILES = 10

  included do
    has_many_attached :attachments
    validate :attachments_are_acceptable
  end

  private

  def attachments_are_acceptable
    return unless attachments.attached?

    errors.add(:attachments, "no máximo #{MAX_FILES} arquivos por envio") if attachments.size > MAX_FILES
    attachments.each do |file|
      unless ALLOWED_CONTENT_TYPES.include?(file.blob.content_type)
        errors.add(:attachments, "#{file.filename}: tipo não permitido (use PNG, JPG, GIF, WEBP ou PDF)")
      end
      errors.add(:attachments, "#{file.filename}: maior que 10 MB") if file.blob.byte_size > MAX_FILE_SIZE
    end
  end
end
