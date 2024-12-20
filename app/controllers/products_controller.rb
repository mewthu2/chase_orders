class ProductsController < ApplicationController
  before_action :load_form_references, only: [:index]
  before_action :set_product, only: %i[edit update]
  skip_before_action :authenticate_user!, only: [:download]  # Ignora autenticação apenas para download

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

  def download
    type = params[:type]
    origin = params[:origin]
    extension = 'csv'

    csv_content = MakeSpreadsheetJob.perform_now(origin, type)

    if csv_content.present?
      mime_type = extension == 'csv' ? 'text/csv' : 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
      filename = "planilha_#{type}_#{origin}.#{extension}"

      send_data csv_content, filename:, type: mime_type
    else
      render plain: 'Erro ao gerar a planilha', status: :unprocessable_entity
    end
  end

  def product_integration
    redirect_to products_path, notice: 'Informações sincronizadas com sucesso.' if ProductIntegrationJob.perform_now('update_product_cost', Product.find(params[:product_id]), current_user)
  end

  private

  def set_product
    @product = Product.find(params[:id])
    @tiny_product = Tiny::Products.find_product(@product.tiny_product_id)
  end

  def load_form_references; end

  def product_params
    params.require(:product)
          .permit(:sku,
                  :tiny_product_id,
                  :shopify_product_id,
                  :shopify_inventory_item_id,
                  :shopify_product_name,
                  :tiny_lagoa_seca_product_id,
                  :tiny_bh_shopping_id,
                  :cost)
  end
end
