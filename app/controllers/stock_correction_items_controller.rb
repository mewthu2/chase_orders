class StockCorrectionItemsController < ApplicationController
  def update
    @item = StockCorrectionItem.find(params[:id])
    
    if @item.update(item_params)
      render json: { success: true }
    else
      render json: { success: false, errors: @item.errors.full_messages }
    end
  end
  
  private
  
  def item_params
    params.require(:stock_correction_item).permit(:checked, :needs_correction, :corrected_stock, :correction_reason)
  end
end
