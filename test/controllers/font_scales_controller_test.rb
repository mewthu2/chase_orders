require 'test_helper'

class FontScalesControllerTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(name: 'Zoom User', email: 'zoom_user@example.com', password: 'password123')
    @user.profiles << Profile.find(Profile::ADMIN)
  end

  test 'saves the font scale for the current user' do
    sign_in @user

    patch font_scale_path, params: { font_scale: 120 }, as: :json

    assert_response :success
    assert_equal 120, @user.reload.font_scale
  end

  test 'clamps the font scale to the allowed range' do
    sign_in @user

    patch font_scale_path, params: { font_scale: 400 }, as: :json

    assert_equal User::FONT_SCALE_RANGE.max, @user.reload.font_scale
  end

  test 'layout applies the saved zoom to the page' do
    @user.update_column(:font_scale, 130)
    sign_in @user

    get b2b_orders_path

    assert_select 'html[style*="zoom: 130%"]'
    assert_select '#fontScale .font-scale-value', text: '130%'
  end

  test 'requires login' do
    patch font_scale_path, params: { font_scale: 120 }, as: :json

    assert_response :unauthorized
  end
end
