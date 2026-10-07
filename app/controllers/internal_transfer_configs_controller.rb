# Configuração das transferências internas (só admin): quem são os aprovadores.
class InternalTransferConfigsController < ApplicationController
  before_action :admin_only!

  def edit
    @users = User.order(:name)
    @approver_ids = InternalTransferApprover.user_ids
  end

  def update
    InternalTransferApprover.replace_with!(Array(params[:approver_ids]).compact_blank)
    redirect_to internal_transfers_path, notice: 'Configuração das transferências salva.'
  end
end
