# Dados fiscais dos produtos (NCM, CEST, origem, unidade), necessários para emitir NF-e.
class FiscalProductsController < ApplicationController
  guard_screen :fiscal_notes

  def index
    scope = Product.order(:sku)
    scope = scope.where(ncm: [nil, '']) if params[:missing].present?
    if params[:q].present?
      term = "%#{params[:q].to_s.downcase}%"
      scope = scope.where('LOWER(products.sku) LIKE :q OR LOWER(products.shopify_product_name) LIKE :q', q: term)
    end
    @products = scope.paginate(page: params[:page], per_page: 50)
    @import_motor = Motor.where(job_name: ImportProductsFiscalDataJob::JOB_NAME).order(:id).last
    @import_running = ImportProductsFiscalDataJob.running?
    @importable_count = ImportProductsFiscalDataJob.eligible_scope.count
  end

  IMPORT_MESSAGES = {
    updated: [:notice, 'dados fiscais importados do Tiny.'],
    already_filled: [:alert, 'já tem NCM; nada foi alterado.'],
    no_tiny_id: [:alert, 'não tem ID em nenhuma conta do Tiny.'],
    not_found: [:alert, 'não foi encontrado no Tiny.'],
    no_ncm_in_tiny: [:alert, 'está sem NCM no Tiny também; preencha manualmente.'],
    invalid_ncm: [:alert, 'tem um NCM inválido no Tiny (esperado 8 dígitos).'],
    rate_limited: [:alert, 'o Tiny bloqueou por excesso de acessos; tente novamente em alguns minutos.'],
    invalid: [:alert, 'os dados do Tiny não passaram na validação.'],
    error: [:alert, 'erro ao consultar o Tiny; tente novamente.']
  }.freeze

  # Puxa do Tiny (somente leitura) os dados fiscais de um produto.
  def import_from_tiny
    product = Product.find(params[:id])
    kind, message = IMPORT_MESSAGES.fetch(product.import_fiscal_data_from_tiny)
    redirect_to fiscal_products_path(index_filters), kind => "#{product.sku}: #{message}"
  end

  # Enfileira a importação em massa dos produtos sem NCM.
  def import_all_from_tiny
    if ImportProductsFiscalDataJob.running?
      redirect_to fiscal_products_path(index_filters), alert: 'A importação do Tiny já está em andamento.'
    else
      ImportProductsFiscalDataJob.perform_later
      redirect_to fiscal_products_path(index_filters), notice: 'Importação do Tiny iniciada em segundo plano. Acompanhe o andamento nesta tela.'
    end
  end

  def update
    product = Product.find(params[:id])
    if product.update(fiscal_params)
      redirect_to fiscal_products_path(index_filters), notice: "Dados fiscais de #{product.sku} atualizados."
    else
      redirect_to fiscal_products_path(index_filters), alert: "#{product.sku}: #{product.errors.full_messages.to_sentence}"
    end
  end

  private

  def fiscal_params
    params.require(:product).permit(:ncm, :cest, :origin, :commercial_unit)
  end

  def index_filters
    params.permit(:q, :missing, :page).to_h.symbolize_keys
  end
end
