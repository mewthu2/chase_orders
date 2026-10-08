# Página pública do catálogo B2B (único controller sem login do app). O lojista escolhe modelos,
# cores e tamanhos e envia uma encomenda; pode alterar até ela virar pedido.
class PublicCatalogsController < ApplicationController
  skip_before_action :authenticate_user!
  layout 'public_catalog'
  before_action :set_catalog

  def show
    @payload = B2bCatalogs::PublicPayload.new(@catalog, current_order).as_json
  end

  def submit
    return fail_with('Este catálogo foi encerrado e não recebe mais encomendas.') if @catalog.closed?

    order = order_for_submit
    return fail_with('Esta encomenda já está em andamento e não pode mais ser alterada. Fale com a Chase.') if order.persisted? && order.converted?

    quantities = submitted_quantities
    return fail_with('Escolha pelo menos uma peça.') if quantities.values.sum <= 0
    if (error = @catalog.quantity_error(quantities))
      return fail_with(error)
    end

    order.assign_attributes(status: :pending, submitted_at: Time.current)
    return fail_with(order.errors.full_messages.to_sentence) unless order.save

    order.replace_items!(quantities, edited_by: 'customer')
    remember(order)
    render json: { ok: true, order: B2bCatalogs::PublicPayload.new(@catalog, order).as_json[:order] }
  end

  def identify
    order = @catalog.catalog_orders.find_by(customer_registration: B2bCatalogs::Cnpj.digits(params[:customer_registration]).presence)
    remember(order) if order
    render json: { ok: true, order: order && B2bCatalogs::PublicPayload.new(@catalog, order).as_json[:order] }
  end

  private

  def set_catalog
    @catalog = B2bCatalog.includes(products: :variants).find_by(public_token: params[:token].to_s)
    return if @catalog

    request.format.json? ? head(:not_found) : render(:unavailable, status: :not_found)
  end

  def cookie_key = "catalog_order_#{@catalog.id}"

  def remember(order)
    cookies.signed[cookie_key] = { value: order.edit_token, expires: 1.year, httponly: true }
  end

  # Encomenda que a página deve mostrar: do cliente (catálogo por cliente) ou a do cookie (geral).
  def current_order
    if @catalog.kind_client?
      @catalog.catalog_orders.first || client_order_template
    else
      token = cookies.signed[cookie_key]
      token.present? ? @catalog.catalog_orders.find_by(edit_token: token) : nil
    end
  end

  def order_for_submit
    return @catalog.catalog_orders.first || client_order_template if @catalog.kind_client?

    registration = B2bCatalogs::Cnpj.digits(params[:customer_registration]).presence
    order = registration ? @catalog.catalog_orders.find_or_initialize_by(customer_registration: registration) : @catalog.catalog_orders.new
    order.customer_name = params[:customer_name].to_s.strip.presence || order.customer_name
    order
  end

  def client_order_template
    client = @catalog.client
    @catalog.catalog_orders.new(client:, customer_name: client.display_name,
                                customer_registration: client.registration.to_s.gsub(/\D/, '').presence)
  end

  def submitted_quantities
    raw = params[:quantities]
    raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
    (raw || {}).to_h.transform_keys(&:to_i).transform_values(&:to_i).reject { |_, q| q <= 0 }
  end

  def fail_with(message)
    render json: { ok: false, error: message }, status: :unprocessable_entity
  end
end
