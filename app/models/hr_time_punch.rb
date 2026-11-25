# Marcação de ponto. Nasce pelo link do funcionário (com foto) ou é incluída pelo RH com justificativa.
# Nunca é apagada: o RH pode desconsiderar, com motivo, e a marcação continua no histórico (Portaria
# MTP 671/2021: o registro original fica preservado e cada um tem um NSR, número sequencial único).
class HrTimePunch < ApplicationRecord
  KINDS = {
    'entrada'         => { label: 'Entrada',            icon: 'fas fa-right-to-bracket', dir: :in,  emoji: '☀️' },
    'saida_intervalo' => { label: 'Saída p/ intervalo', icon: 'fas fa-mug-hot',          dir: :out, emoji: '🍽️' },
    'volta_intervalo' => { label: 'Volta do intervalo', icon: 'fas fa-person-walking-arrow-loop-left', dir: :in, emoji: '💪' },
    'saida'           => { label: 'Saída',              icon: 'fas fa-right-from-bracket', dir: :out, emoji: '🌙' }
  }.freeze
  SOURCES = { 'link' => 'Link com foto', 'manual' => 'Incluída pelo RH' }.freeze
  PHOTO_TYPES = %w[image/jpeg image/png image/webp].freeze
  PHOTO_MAX = 3.megabytes

  belongs_to :employee, class_name: 'HrEmployee', foreign_key: :hr_employee_id, inverse_of: :time_punches
  belongs_to :created_by, class_name: 'User', optional: true
  belongs_to :annulled_by, class_name: 'User', optional: true
  has_one_attached :photo

  validates :kind, inclusion: { in: KINDS.keys }
  validates :source, inclusion: { in: SOURCES.keys }
  validates :punched_at, :work_date, presence: true
  validates :note, presence: { message: 'conte o motivo da inclusão' }, if: -> { source == 'manual' }
  validate :photo_required, if: -> { source == 'link' }

  before_validation :assign_nsr, on: :create

  scope :effective, -> { where(annulled_at: nil) }
  scope :chronological, -> { order(:punched_at, :id) }

  def label = KINDS.dig(kind, :label)
  def icon = KINDS.dig(kind, :icon)
  def in? = KINDS.dig(kind, :dir) == :in
  def out? = !in?
  def annulled? = annulled_at.present?
  def manual? = source == 'manual'
  def local_time = punched_at.in_time_zone(employee.time_zone)
  def nsr_text = nsr.to_s.rjust(9, '0')

  def annul!(user, reason)
    update!(annulled_at: Time.current, annulled_by: user, annul_reason: reason)
  end

  # Foto vinda da câmera como data URL ("data:image/jpeg;base64,...").
  def photo_data_url=(data)
    match = data.to_s.match(%r{\Adata:(image/(?:jpeg|png|webp));base64,(.+)\z}m)
    return unless match

    bytes = Base64.decode64(match[2])
    @photo_too_big = bytes.bytesize > PHOTO_MAX
    return if @photo_too_big

    ext = match[1].split('/').last.sub('jpeg', 'jpg')
    photo.attach(io: StringIO.new(bytes), filename: "ponto-#{SecureRandom.hex(6)}.#{ext}", content_type: match[1])
  end

  private

  # NSR sequencial único. A trava evita dois iguais; se mesmo assim colidir, o índice único recusa e o
  # controller tenta de novo.
  def assign_nsr
    self.nsr ||= (self.class.lock.maximum(:nsr) || 0) + 1
  end

  def photo_required
    return errors.add(:photo, 'passa de 3 MB') if @photo_too_big
    return errors.add(:photo, 'é obrigatória: tire a foto para bater o ponto') unless photo.attached?

    errors.add(:photo, 'precisa ser JPG, PNG ou WebP') unless PHOTO_TYPES.include?(photo.blob.content_type)
  end
end
