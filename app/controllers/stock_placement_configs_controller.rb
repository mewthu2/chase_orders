# Colocação de estoque › Configurações: empresa, natureza de operação e destinatário da nota de remessa do Log02
# e do Log03.
class StockPlacementConfigsController < ApplicationController
  guard_screen :stock_placements, actions: { edit: :edit, update: :edit }

  def edit
    @configs = StockPlacement::SIDES.keys.index_with { |side| StockPlacementConfig.for(side) }
    @companies = Company.where(active: true).order(:trade_name).to_a
    @natures = OperationNature.where(active: true).includes(:company).order(:description).to_a
  end

  def update
    StockPlacement::SIDES.each_key do |side|
      data = params.dig(:configs, side) or next
      config = StockPlacementConfig.for(side)
      recipient = B2bSetting::REMESSA_RECIPIENT_FIELDS.to_h { |f| [f, data.dig(:recipient, f).to_s.strip] }
      config.update!(company_id: data[:company_id].presence, operation_nature_id: data[:operation_nature_id].presence,
                     recipient: recipient.values.any?(&:present?) ? recipient : nil)
    end
    redirect_to edit_stock_placement_config_path, notice: 'Configurações da colocação de estoque salvas.'
  end
end
