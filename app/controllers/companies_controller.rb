class CompaniesController < ApplicationController
  guard_screen :companies
  before_action :set_company, only: [:edit, :update, :destroy, :toggle_environment]

  def index
    @companies = Company.includes(:certificate_attachment, :location).order(:legal_name)
    @note_counts = FiscalNote.group(:company_id).count
  end

  def new
    @company = Company.new(environment: :homologacao)
  end

  def create
    @company = Company.new(company_params)
    if @company.save
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

    if @company.update(attrs)
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

  def company_params
    params.require(:company).permit(
      :legal_name, :trade_name, :cnpj, :state_registration, :municipal_registration, :cnae, :tax_regime,
      :street, :number, :complement, :neighbourhood, :city, :city_ibge_code, :state, :zip, :phone, :email,
      :environment, :nfe_series, :next_nfe_number, :next_nfe_number_homologation,
      :cfop_sale_in_state, :cfop_sale_out_of_state, :cfop_transfer_in_state, :cfop_transfer_out_of_state,
      :operation_nature_sale, :operation_nature_transfer, :icms_situation, :pis_cst, :cofins_cst,
      :active, :certificate_file, :certificate_password, :location_id
    )
  end
end
