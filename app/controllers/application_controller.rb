class ApplicationController < ActionController::Base
  include Common

  before_action :authenticate_user!
  before_action :preload_current_user
  protect_from_forgery unless: -> { request.format.json? }

  layout 'layouts/application'

  helper_method :true_user, :impersonating?, :screen_can?

  # Nome legível (helpers e views) → letra gravada na permissão.
  ACTION_LETTERS = { view: 'V', create: 'C', edit: 'E', approve: 'A', execute: 'X', destroy: 'D', export: 'P' }.freeze

  # Protege o controller pela permissão da tela. A ação exigida sai do nome da action
  # (ver screen_action_letter); `actions:` corrige casos específicos ({ revert: :destroy }).
  # A chave pode ser calculada por request com um bloco (ou uma lista: basta ter uma delas).
  def self.guard_screen(key = nil, actions: {}, **options, &resolver)
    overrides = actions.transform_keys(&:to_s).transform_values { |v| ACTION_LETTERS.fetch(v.to_sym, v.to_s) }
    before_action(**options) do
      keys = resolver ? instance_exec(&resolver) : key
      authorize_screen!(keys, screen_action_letter(overrides))
    end
  end

  # Quem está de fato no teclado: o super admin quando está logado como outro usuário.
  def true_user
    return current_user unless impersonating?

    @true_user ||= User.find(session[:impersonator_id])
  end

  def impersonating?
    session[:impersonator_id].present? && User.find_by(id: session[:impersonator_id])&.super_admin?
  end

  # Para as views esconderem botões: screen_can?(:b2b_orders, :create).
  def screen_can?(screen_key, action = :view)
    current_user.present? && current_user.can?(screen_key, ACTION_LETTERS.fetch(action.to_sym, action.to_s))
  end

  private

  # Perfis e foto do usuário logado, carregados antes das listas da tela. Assim o cabeçalho e as
  # permissões não consultam de novo, e o Bullet não confunde o usuário logado com um N+1 de uma
  # lista que por acaso também o contém.
  def preload_current_user
    return unless current_user && request.get? && request.format.html?

    ActiveRecord::Associations::Preloader.new(records: [current_user], associations: %i[profiles avatar_attachment]).call
  end

  def admin_only!
    redirect_to root_path, alert: 'Acesso negado. Apenas administradores podem acessar esta funcionalidade.' unless current_user&.admin?
  end

  def admin_or_manager!
    redirect_to root_path, alert: 'Acesso negado.' unless current_user&.admin? || current_user&.manager?
  end

  EXPORT_ACTION = /export|xlsx|csv|pdf|xml|danfe|romaneio|download/
  APPROVE_ACTION = /\A(approve|reject|ignore)/

  def screen_action_letter(overrides = {})
    name = action_name.to_s
    return overrides[name] if overrides.key?(name)
    return 'P' if request.format.symbol.in?(%i[xlsx csv pdf xml]) || name.match?(EXPORT_ACTION)

    case name
    when 'index', 'show' then 'V'
    when 'new', 'create' then 'C'
    when 'edit', 'update' then 'E'
    when 'destroy' then 'D'
    else
      return 'A' if name.match?(APPROVE_ACTION)

      request.get? || request.head? ? 'V' : 'X'
    end
  end

  # Telas que não têm a ação pedida (ex.: "Exportar" numa tela sem exportação) caem em "Ver".
  def authorize_screen!(screen_keys, letter = 'V')
    keys = Array(screen_keys).map(&:to_s)
    allowed = keys.any? do |key|
      needed = Screen.acts(key).include?(letter) ? letter : 'V'
      current_user&.can?(key, needed)
    end
    return if allowed

    denied_screen!(keys.first, letter)
  end

  def denied_screen!(screen_key, letter)
    can_view = current_user&.can?(screen_key, 'V')
    message = if can_view
                "Seu perfil não permite #{Screen::ACTIONS.dig(letter, :label)&.downcase || 'esta ação'} em #{Screen.label(screen_key)}."
              else
                'Acesso negado.'
              end

    respond_to do |format|
      format.html { redirect_back fallback_location: root_path, alert: message }
      format.any { render json: { error: message }, status: :forbidden }
    end
  end
end
