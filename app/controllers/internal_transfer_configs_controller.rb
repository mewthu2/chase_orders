# Configuração das transferências internas (só admin): quem é o aprovador.
class InternalTransferConfigsController < ApplicationController
  before_action :admin_only!

  def edit
    @config = InternalTransferConfig.current
    @users = User.order(:name)
  end

  def update
    @config = InternalTransferConfig.current
    @config.update!(approver_id: params.require(:internal_transfer_config)[:approver_id].presence)
    redirect_to internal_transfers_path, notice: 'Configuração das transferências salva.'
  end
end
