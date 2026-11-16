# Configurações das transferências internas (só admin): quem são os aprovadores e, para a nota fiscal das
# remessas, a loja de cada empresa emissora e a natureza de transferência que ela usa.
class InternalTransferConfigsController < ApplicationController
  before_action :admin_only!

  def edit
    load_form
  end

  def update
    choices = company_choices
    error = validate_choices(choices)
    if error
      load_form
      flash.now[:alert] = error
      render :edit, status: :unprocessable_entity
      return
    end

    ActiveRecord::Base.transaction do
      InternalTransferApprover.replace_with!(Array(params[:approver_ids]).compact_blank)
      apply_choices!(choices)
    end
    redirect_to internal_transfers_path, notice: 'Configurações das transferências salvas.'
  end

  private

  def load_form
    @users = User.includes(:profiles).order(:name)
    @approver_ids = params.key?(:approver_ids) ? Array(params[:approver_ids]).compact_blank.map(&:to_i) : InternalTransferApprover.user_ids
    @companies = Company.includes(:location).order(:id).to_a
    @locations = Location.order(:name).to_a
    @transfer_natures = OperationNature.transfer.where(active: true).order(:description).to_a
  end

  # { company => { location_id:, nature_id: } } vindo de companies[<id>][location_id|internal_transfer_nature_id].
  def company_choices
    raw = params.fetch(:companies, {}).permit!.to_h
    Company.where(id: raw.keys).index_by { |c| c.id.to_s }.to_h do |id, company|
      [company, { location_id: raw.dig(id, 'location_id').presence&.to_i,
                  nature_id: raw.dig(id, 'internal_transfer_nature_id').presence&.to_i }]
    end
  end

  def validate_choices(choices)
    taken = choices.values.filter_map { |c| c[:location_id] }
    repeated = taken.select { |id| taken.count(id) > 1 }.uniq
    if repeated.any?
      return "Cada loja só pode ser de uma empresa: #{Location.where(id: repeated).pluck(:name).to_sentence} está em mais de uma."
    end

    natures = OperationNature.where(id: choices.values.filter_map { |c| c[:nature_id] }).index_by(&:id)
    choices.each do |company, choice|
      nature = natures[choice[:nature_id]]
      next unless choice[:nature_id]
      return 'Natureza de operação não encontrada.' unless nature
      return "\"#{nature.description}\" não é uma natureza de transferência ativa." unless nature.transfer? && nature.active?
      unless nature.compatible_with?(company)
        return "A natureza \"#{nature.description}\" usa #{nature.regime_label} e não serve para #{company.legal_name}."
      end
    end
    nil
  end

  # A emissão só aceita natureza vinculada à empresa: escolher aqui já vincula (como na Configuração do atacado).
  def apply_choices!(choices)
    choices.each do |company, choice|
      company.location_id = choice[:location_id]
      company.internal_transfer_nature_id = choice[:nature_id]
      company.save!(validate: false)
      CompanyOperationNature.find_or_create_by!(company:, operation_nature_id: choice[:nature_id]) if choice[:nature_id]
    end
  end
end
