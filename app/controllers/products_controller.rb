class ProductsController < ApplicationController
  before_action :load_form_references, only: [:index]
  before_action :set_product, only: %i[edit update]

  def index
    @products = Product.search(params[:search])
                       .order(updated_at: :asc)
                       .paginate(page: params[:page], per_page: params_per_page(params[:per_page]))
  end

  # GET /products/1/edit
  def edit; end

  # PATCH/PUT /products/1
  def update
    if @product.update(product_params)
      redirect_to products_path, notice: 'Produto atualizado com sucesso.'
    else
      render :edit
    end
  end

  def product_integration
    redirect_to products_path, notice: 'Informações sincronizadas com sucesso.' if ProductIntegrationJob.perform_now('update_product_cost', Product.find(params[:product_id]), current_user)
  end

  private

  # Set product by ID
  def set_product
    @product = Product.find(params[:id])
    @tiny_product = Tiny::Products.find_product(@product.tiny_product_id)
  end

  def load_form_references; end

  # It allows only useful parameters.
  def product_params
    params.require(:product)
          .permit(:sku,
                  :tiny_product_id,
                  :shopify_product_id,
                  :shopify_inventory_item_id,
                  :shopify_product_name,
                  :cost)
  end
end
