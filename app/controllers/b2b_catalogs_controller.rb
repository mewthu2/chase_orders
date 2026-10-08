# Montagem dos catálogos B2B e a lista de encomendas de cada um.
class B2bCatalogsController < ApplicationController
  guard_screen :b2b_catalogs
  before_action :set_catalog, only: %i[show edit update toggle_status regenerate_token refresh pdf]

  def index
    @catalogs = B2bCatalog.includes(:client).order(created_at: :desc)
    @order_counts = B2bCatalogOrder.group(:b2b_catalog_id).count
    @pending_counts = B2bCatalogOrder.pending.group(:b2b_catalog_id).count
  end

  def show
    @catalog_orders = @catalog.catalog_orders.includes(:items).order(:status, updated_at: :desc)
  end

  def new
    @catalog = B2bCatalog.new(kind: :general)
  end

  def create
    @catalog = B2bCatalog.new(catalog_params.merge(user: current_user))

    if @catalog.save
      B2bCatalogRefreshJob.perform_later(@catalog.id)
      redirect_to b2b_catalog_path(@catalog), notice: 'Catálogo criado. Estoque e fotos estão sendo atualizados.'
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @catalog.update(catalog_params)
      B2bCatalogRefreshJob.perform_later(@catalog.id)
      redirect_to b2b_catalog_path(@catalog), notice: 'Catálogo atualizado.'
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def toggle_status
    @catalog.update!(status: @catalog.active? ? :closed : :active)
    redirect_to b2b_catalog_path(@catalog), notice: @catalog.active? ? 'Catálogo reaberto.' : 'Catálogo encerrado: o link mostra que ele foi encerrado.'
  end

  def regenerate_token
    @catalog.regenerate_public_token!
    redirect_to b2b_catalog_path(@catalog), notice: 'Novo link gerado. O link antigo deixou de funcionar.'
  end

  def refresh
    B2bCatalogRefreshJob.perform_later(@catalog.id)
    redirect_to b2b_catalog_path(@catalog), notice: 'Atualização de estoque e fotos iniciada.'
  end

  def pdf
    pdf = B2bCatalogPdf.new(@catalog, public_url: public_catalog_url(@catalog.public_token))
    send_data pdf.render, filename: pdf.filename, type: 'application/pdf', disposition: 'attachment'
  end

  # Busca para o seletor: cada resultado é uma cor (produto do Shopify) com todos os seus SKUs.
  def product_picker
    tokens = params[:query].to_s.downcase.split(/\s+/).reject(&:blank?)
    products = if tokens.empty?
                 Product.none
               else
                 tokens.reduce(Product.all) do |scope, token|
                   scope.where('LOWER(sku) LIKE :q OR LOWER(shopify_product_name) LIKE :q', q: "%#{token}%")
                 end.limit(400)
               end

    groups = products.group_by { |p| p.shopify_product_id.presence || p.shopify_product_name.presence || p.sku }.values.first(40)
    render json: { products: groups.map { |variants| picker_entry(variants) } }
  end

  def split_names
    render json: B2bCatalogs::NameSplitter.split(Array(params[:names]).map(&:to_s))
  end

  private

  def set_catalog
    @catalog = B2bCatalog.find(params[:id])
  end

  def catalog_params
    params.require(:b2b_catalog).permit(:title, :kind, :client_id, :notes,
                                        products_attributes: [:id, :style_name, :color_name, :position, :_destroy, { skus: [] }])
  end

  def picker_entry(variants)
    sorted = variants.sort_by { |v| B2bCatalogProduct::SIZE_ORDER.index(v.option1.to_s.upcase) || 99 }
    { name: variants.first.shopify_product_name.presence || variants.first.sku,
      image_url: variants.find { |v| v.image_url.present? }&.image_url,
      skus: sorted.map(&:sku),
      sizes: sorted.map { |v| v.option1.presence || v.sku } }
  end
end
