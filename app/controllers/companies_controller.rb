class CompaniesController < ApplicationController
  guard_screen :companies
  before_action :set_company, only: [:edit, :update, :destroy, :toggle_environment]

  def index
    @companies = Company.includes(:certificate_attachment, :location, :available_natures).order(:legal_name)
    @note_counts = FiscalNote.group(:company_id).count
  end

  def new
    @company = Company.new(environment: :homologacao)
  end

  def create
    @company = Company.new(company_params)
    saved = Company.transaction do
      (@company.save && link_natures?) || raise(ActiveRecord::Rollback)
    end
    if saved
      redirect_to companies_path, notice: 'Empresa criada com sucesso.'
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    attrs = company_params
    # Senha em branco sem arquivo novo = manter o certificado e a senha atuais.
    attrs = attrs.except(:certificate_password) if attrs[:certificate_password].blank? && attrs[:certificate_file].blank?

    saved = Company.transaction do
      (@company.update(attrs) && link_natures?) || raise(ActiveRecord::Rollback)
    end
    if saved
      redirect_to companies_path, notice: 'Empresa atualizada com sucesso.'
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    if @company.destroy
      redirect_to companies_path, notice: 'Empresa removida com sucesso.'
    else
      redirect_to companies_path, alert: 'Não é possível excluir: a empresa já possui notas fiscais.'
    end
  end

  # Liga/desliga produção direto da lista, sem passar pelo formulário (que revalidaria o certificado).
  def toggle_environment
    target = @company.homologacao? ? :producao : :homologacao
    @company.update_column(:environment, Company.environments[target])
    redirect_back fallback_location: companies_path,
                  notice: "#{@company.legal_name} agora emite em #{@company.reload.environment_label.downcase}."
  end

  private

  def set_company
    @company = Company.find(params[:id])
  end

  # Naturezas de operação marcadas no formulário (o campo vazio garante que dá para desmarcar todas).
  def link_natures?
    return true unless params[:company]&.key?(:nature_ids)

    @company.link_natures(params[:company][:nature_ids])
  end

  def company_params
    params.require(:company).permit(
      :legal_name, :trade_name, :cnpj, :state_registration, :municipal_registration, :cnae, :tax_regime,
      :street, :number, :complement, :neighbourhood, :city, :city_ibge_code, :state, :zip, :phone, :email,
      :environment, :nfe_series, :next_nfe_number, :next_nfe_number_homologation,
      :active, :certificate_file, :certificate_password, :location_id
    )
  end
end
