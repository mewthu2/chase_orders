class Log < ApplicationRecord
  belongs_to :user

  validates :resource_type, presence: true
  validates :action_type, presence: true

  scope :recent, -> { order(created_at: :desc) }
  scope :by_resource_type, ->(type) { where(resource_type: type) }
  scope :by_action_type, ->(action) { where(action_type: action) }
  scope :by_user, ->(user_id) { where(user_id: user_id) }
  scope :successful, -> { where(success: true) }
  scope :failed, -> { where(success: false) }

  def details_parsed
    return {} if details.blank?
    JSON.parse(details)
  rescue JSON::ParserError
    {}
  end

  def old_values_parsed
    return {} if old_values.blank?
    JSON.parse(old_values)
  rescue JSON::ParserError
    {}
  end

  def new_values_parsed
    return {} if new_values.blank?
    JSON.parse(new_values)
  rescue JSON::ParserError
    {}
  end

  def action_description
    case action_type
    when 'search'
      'Busca'
    when 'activate'
      'Ativação'
    when 'deactivate'
      'Desativação'
    when 'update'
      'Atualização'
    when 'create'
      'Criação'
    when 'delete'
      'Exclusão'
    when 'update_dates'
      'Atualização de datas'
    else
      action_type.humanize
    end
  end

  def resource_type_description
    case resource_type
    when 'discount'
      'Cupom de Desconto'
    when 'product'
      'Produto'
    when 'order'
      'Pedido'
    when 'user'
      'Usuário'
    else
      resource_type.humanize
    end
  end

  def status_badge_class
    success? ? 'bg-success' : 'bg-danger'
  end

  def action_badge_class
    case action_type
    when 'search'
      'bg-info'
    when 'activate'
      'bg-success'
    when 'deactivate'
      'bg-danger'
    when 'update', 'update_dates'
      'bg-warning text-dark'
    when 'create'
      'bg-primary'
    when 'delete'
      'bg-danger'
    else
      'bg-secondary'
    end
  end

  def action_icon
    case action_type
    when 'search'
      'fas fa-search'
    when 'activate'
      'fas fa-check-circle'
    when 'deactivate'
      'fas fa-times-circle'
    when 'update', 'update_dates'
      'fas fa-edit'
    when 'create'
      'fas fa-plus-circle'
    when 'delete'
      'fas fa-trash'
    else
      'fas fa-cog'
    end
  end
end