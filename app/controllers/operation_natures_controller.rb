class OperationNaturesController < ApplicationController
  guard_screen :companies
  before_action :set_nature, only: [:edit, :update, :destroy]
  before_action :load_companies, only: [:new, :create, :edit, :update]

  def index
    @natures = OperationNature.includes(:company, :icms_exceptions).order(:company_id, :kind, :description)
    @note_counts = FiscalNote.where.not(operation_nature_id: nil).group(:operation_nature_id).count
  end

  def new
    company = Company.active.order(:legal_name).first
    @nature = OperationNature.new(company: company, kind: :sale, cfop: '?102', final_consumer: true,
                                  icms_situation: company&.tax_regime == 3 ? '00' : '102',
                                  pis_cst: company&.tax_regime == 3 ? '01' : '49',
                                  cofins_cst: company&.tax_regime == 3 ? '01' : '49')
  end

  def create
    @nature = OperationNature.new(nature_params)
    if @nature.save
      redirect_to operation_natures_path, notice: 'Natureza de operação criada.'
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @nature.update(nature_params)
      redirect_to operation_natures_path, notice: 'Natureza de operação atualizada.'
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    if @nature.destroy
      redirect_to operation_natures_path, notice: 'Natureza de operação removida.'
    else
      redirect_to operation_natures_path, alert: 'Esta natureza já tem notas emitidas: desative em vez de excluir.'
    end
  end

  private

  def set_nature
    @nature = OperationNature.find(params[:id])
  end

  def load_companies
    @companies = Company.order(:legal_name)
  end

  def nature_params
    permitted = params.require(:operation_nature).permit(
      :company_id, :description, :kind, :default_for_kind, :purpose, :final_consumer, :cfop,
      :cfop_interstate_non_contributor, :icms_situation, :icms_rate, :difal, :pis_cst, :pis_rate, :cofins_cst,
      :cofins_rate, :exclude_icms_from_pis_cofins_base, :notes, :fisco_notes, :active,
      :ibs_cbs_mode, :ibs_cbs_cst, :ibs_cbs_class, :ibs_uf_rate, :ibs_mun_rate, :cbs_rate,
      uf_rates: Company::STATES.keys.index_with { %i[internal fcp] },
      icms_exceptions_attributes: [:id, :_destroy, :icms_situation, :cfop, :icms_rate, :difal, :fcp_rate, :notes,
                                   :fisco_notes, { destination_states: [], origin_states: [] }]
    )
    permitted[:uf_rates] = permitted[:uf_rates].to_h if permitted[:uf_rates]
    permitted
  end
end
