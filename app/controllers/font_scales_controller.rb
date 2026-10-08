# Tamanho da fonte (zoom) do sistema, escolhido por cada usuário ao lado do nome no menu.
class FontScalesController < ApplicationController
  def update
    scale = params[:font_scale].to_i.clamp(User::FONT_SCALE_RANGE.min, User::FONT_SCALE_RANGE.max)
    current_user.update_column(:font_scale, scale)
    render json: { success: true, font_scale: scale }
  end
end
