class CustomersController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin!

  LOCATION_COLORS = [
    { bg: '#0D6EFD', fg: '#fff' },
    { bg: '#198754', fg: '#fff' },
    { bg: '#DC3545', fg: '#fff' },
    { bg: '#FFC107', fg: '#000' },
    { bg: '#0DCAF0', fg: '#000' },
    { bg: '#6F42C1', fg: '#fff' },
    { bg: '#FD7E14', fg: '#fff' },
    { bg: '#20C997', fg: '#000' },
  ].freeze

  def index
    @per_page     = (params[:per_page] || 20).to_i
    @current_page = (params[:page] || 1).to_i
    offset        = (@current_page - 1) * @per_page

    @locations       = Location.order(:name)
    @location_colors = build_location_colors(@locations)

    base_query   = build_query
    @customers   = base_query.limit(@per_page).offset(offset)
    @total       = base_query.count
    @total_pages = (@total.to_f / @per_page).ceil
  end

  def show
    @customer = Customer.find(params[:id])
    @orders   = Order.includes(:location, order_items: :product)
                     .where(customer_id: @customer.id)
                     .order(created_at: :desc)

    respond_to do |format|
      format.json do
        render json: {
          customer: @customer,
          orders: @orders.map do |o|
            {
              id:                    o.id,
              shopify_order_id:      o.shopify_order_id,
              location_name:         o.location&.name,
              location_id:           o.location_id,
              shopify_creation_date: o.shopify_creation_date&.strftime('%d/%m/%Y %H:%M'),
              created_at:            o.created_at.strftime('%d/%m/%Y %H:%M'),
              total_items:           o.order_items.sum(&:quantity),
              total_value:           o.order_items.sum { |i| i.price.to_f * i.quantity },
              items: o.order_items.map do |item|
                {
                  id:              item.id,
                  sku:             item.sku,
                  price:           item.price.to_f,
                  quantity:        item.quantity,
                  canceled:        item.canceled,
                  product_name:    item.product&.shopify_product_name,
                  product_option1: item.product&.option1,
                  product_option2: item.product&.option2,
                  image_url:       item.product&.image_url
                }
              end
            }
          end
        }
      end
    end
  end

  def coupons
    @customer = Customer.find(params[:id])

    respond_to do |format|
      format.json { render json: coupons_status_payload(@customer) }
    end
  end

  private

  def coupons_status_payload(customer)
    raw = $redis.get(FetchCustomerCouponsJob.result_key(customer.id))

    if raw
      result = JSON.parse(raw, symbolize_names: true)
      return { status: 'error', error: result[:error] } if result[:error]

      return { status: 'done', coupons: result[:coupons] }
    end

    processing_key = FetchCustomerCouponsJob.processing_key(customer.id)
    acquired_lock = $redis.set(processing_key, '1', nx: true, ex: FetchCustomerCouponsJob::PROCESSING_TTL)
    FetchCustomerCouponsJob.perform_later(customer.id) if acquired_lock

    { status: 'processing' }
  rescue Redis::BaseError => e
    { status: 'error', error: e.message }
  end

  def build_query
    query = Customer.order(created_at: :desc)

    if params[:search].present?
      term  = "%#{params[:search]}%"
      query = query.where(
        "first_name LIKE ? OR last_name LIKE ? OR email LIKE ? OR phone LIKE ? OR CONCAT_WS(' ', first_name, last_name) LIKE ?",
        term, term, term, term, term
      )
    end

    if params[:location_id].present?
      query = query.where(
        id: Order.select(:customer_id).where(location_id: params[:location_id])
      )
    end

    query
  end

  def build_location_colors(locations)
    colors = {}
    locations.each_with_index { |loc, i| colors[loc.id] = LOCATION_COLORS[i % LOCATION_COLORS.size] }
    colors
  end

  def require_admin!
    unless current_user&.admin? || current_user&.profiles&.any?(&:marketing_profile?)
      redirect_to root_path, alert: "Acesso restrito a administradores."
    end
  end
end