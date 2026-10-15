class CashbackUnificationsController < ApplicationController
  protect_from_forgery with: :exception
  guard_screen :cashback_unifications
  before_action :html_only!
  before_action :set_unification, only: [:show, :confirm]

  def index
    @unifications = visible_unifications.includes(:user, :customer).order(created_at: :desc).limit(30)
  end

  def new
    load_customers
  end

  # Preview is persisted so confirmation accepts only its ID, never browser-supplied amounts.
  def create
    @customer = Customer.find_by(id: params[:customer_id])
    preview = Cashback::Preview.new.call(
      codes: [params[:first_code], params[:second_code]], customer: @customer,
      ownership_confirmed: params[:ownership_confirmed] == '1'
    )
    unification = CashbackUnification.create!(preview.merge(user: current_user, code: "UNF#{SecureRandom.hex(8).upcase}"))
    redirect_to cashback_unification_path(unification)
  rescue Cashback::Preview::Error, Cashback::ShopifyGateway::Error => error
    preview_error(error.message)
  rescue StandardError => error
    Rails.logger.error("Cashback preview: #{error.class}")
    preview_error('Não foi possível consultar os cupons. Tente novamente em instantes.')
  end

  def show; end

  def confirm
    return head :forbidden unless @unification.user_id == current_user.id

    Cashback::Unify.new(@unification).call
    redirect_to cashback_unification_path(@unification), notice: 'Cupons unificados! Os dois MTZ foram desativados.'
  rescue Cashback::Unify::Error => error
    redirect_to cashback_unification_path(@unification), alert: error.message
  end

  private

  def html_only!
    head :not_acceptable unless request.format.html?
  end

  def visible_unifications
    current_user.admin? ? CashbackUnification.all : CashbackUnification.where(user: current_user)
  end

  def set_unification
    @unification = visible_unifications.find(params[:id])
  end

  def load_customers
    @search = params[:search].to_s.strip.first(100)
    @customers = if @customer
                   [@customer]
                 elsif @search.length >= 3
                   term = "%#{Customer.sanitize_sql_like(@search)}%"
                   Customer.where('email LIKE ? OR phone LIKE ? OR CONCAT_WS(\' \', first_name, last_name) LIKE ?', term, term, term)
                           .where.not(shopify_customer_id: [nil, '']).order(:first_name, :last_name).limit(20)
                 else
                   []
                 end
  end

  def preview_error(message)
    load_customers
    flash.now[:alert] = message
    render :new, status: :unprocessable_entity
  end
end
