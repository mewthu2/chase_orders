class ProductsController < ApplicationController
  before_action :set_product, only: [:show, :edit, :update, :destroy]

  # GET /products
  def index
    @products = Product.all
  end

  # GET /products/1
  def show; end

  # GET /products/new
  def new
    @product = Product.new
  end

  # GET /products/1/edit
  def edit; end

  # POST /products
  def create
    @product = Product.new(product_params)

    if @product.save
      redirect_to @product, notice: 'Product was successfully created.'
    else
      render :new
    end
  end

  # PATCH/PUT /products/1
  def update
    if @product.update(product_params)
      redirect_to @product, notice: 'Product was successfully updated.'
    else
      render :edit
    end
  end

  # DELETE /products/1
  def destroy
    @product.destroy
    redirect_to products_url, notice: 'Product was successfully destroyed.'
  end

  private

  def set_product
    @product = Product.find(params[:id])

    if @product.tiny_rj_id.present?
      token = ENV.fetch('TOKEN_TINY_PRODUCTION_RJ')
      @tiny_product = Tiny::Products.find_product(@product.tiny_rj_id, token)
    elsif @product.tiny_bh_shopping_id.present?
      token = ENV.fetch('TOKEN_TINY_PRODUCTION_BH_SHOPPING')
      @tiny_product = Tiny::Products.find_product(@product.tiny_bh_shopping_id, token)
    elsif @product.tiny_lagoa_seca_product_id.present?
      token = ENV.fetch('TOKEN_TINY_PRODUCTION')
      @tiny_product = Tiny::Products.find_product(@product.tiny_lagoa_seca_product_id, token)
    else
      @tiny_product = nil
    end
  end

  def product_params
    params.require(:product).permit(
      :sku, :shopify_product_name, :tiny_rj_id, :tiny_bh_shopping_id, 
      :tiny_lagoa_seca_product_id, :shopify_product_id, :shopify_inventory_item_id, 
      :cost, :price, :compare_at_price, :vendor, :tags
    )
  end
end
