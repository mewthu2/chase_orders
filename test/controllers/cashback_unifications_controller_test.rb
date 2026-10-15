require 'test_helper'
require 'minitest/mock'
require_relative '../support/cashback_factory'

class CashbackUnificationsControllerTest < ActionDispatch::IntegrationTest
  include CashbackFactory
  self.fixture_table_names = []

  setup do
    setup_cashback
    sign_in @user
  end
  teardown { travel_back }

  def valid_params
    { customer_id: @customer.id, first_code: 'MTZA', second_code: 'MTZB', ownership_confirmed: '1' }
  end

  test 'manager sees navigation, customer search and coupon form' do
    get cashback_unifications_path
    assert_response :success
    assert_select 'a', text: 'Cupons de cashback'
    get new_cashback_unification_path, params: { search: 'Ana' }
    assert_response :success
    assert_select "input[name='customer_id'][value='#{@customer.id}']"
    assert_select "input[name='first_code']"
    assert_select "input[name='second_code']"
    assert_select "input[name='ownership_confirmed']"
  end

  test 'preview ignores client submitted values and never changes Shopify' do
    Cashback::ShopifyGateway.stub(:new, @gateway) do
      assert_difference 'CashbackUnification.count', 1 do
        post cashback_unifications_path, params: valid_params.merge(amount: '99999', expires_at: '2099-01-01')
      end
    end
    record = CashbackUnification.last
    assert_redirected_to cashback_unification_path(record)
    assert_equal BigDecimal('50.30'), record.amount
    assert_equal 1.day.from_now, record.expires_at
    assert record.draft?
    assert_empty @gateway.writes
    follow_redirect!
    assert_select "form[action='#{confirm_cashback_unification_path(record)}']"
    assert_select '#unified-code', count: 0
    assert_includes response.body, '250,03'
  end

  test 'confirmation displays verified code and duplicate confirmation is idempotent' do
    record = draft_unification
    Cashback::ShopifyGateway.stub(:new, @gateway) do
      2.times { post confirm_cashback_unification_path(record), params: { amount: '99999' } }
    end
    assert record.reload.completed?
    assert_equal 3, @gateway.writes.size
    follow_redirect!
    assert_select "#unified-code[value='#{record.code}']"
    assert_select "form[action='#{confirm_cashback_unification_path(record)}']", count: 0
  end

  test 'invalid input shows useful error and preserves codes' do
    Cashback::ShopifyGateway.stub(:new, @gateway) do
      post cashback_unifications_path, params: valid_params.merge(second_code: 'MTZA')
    end
    assert_response :unprocessable_entity
    assert_includes response.body, 'dois cupons MTZ diferentes'
    assert_select "input[name='first_code'][value='MTZA']"
  end

  test 'unprivileged users cannot access any route' do
    record = draft_unification
    @user.profiles.first.screen_permissions.delete_all
    get cashback_unifications_path
    assert_redirected_to root_path
    get new_cashback_unification_path
    assert_redirected_to root_path
    post cashback_unifications_path, params: valid_params
    assert_redirected_to root_path
    get cashback_unification_path(record)
    assert_redirected_to root_path
    post confirm_cashback_unification_path(record)
    assert_redirected_to root_path
    assert record.reload.draft?
  end

  test 'another manager cannot inspect or confirm someone elses operation' do
    record = draft_unification
    other = User.create!(name: 'Outra gerente', email: 'other_cashback@example.com', password: 'password123', profiles: @user.profiles)
    sign_in other
    get cashback_unification_path(record)
    assert_response :not_found
    sign_in other
    post confirm_cashback_unification_path(record)
    assert_response :not_found
    assert record.reload.draft?
  end

  test 'administrators can inspect operations needing review without exposing usable code to manager' do
    record = draft_unification
    record.update!(status: :needs_review, step: 'create')
    get cashback_unification_path(record)
    assert_response :success
    assert_select '#unified-code', count: 0
    assert_select "form[action='#{confirm_cashback_unification_path(record)}']", count: 0
    refute_includes response.body, record.code
    @user.profiles << Profile.find(Profile::ADMIN)
    get cashback_unification_path(record)
    assert_includes response.body, record.code
  end

  test 'JSON requests cannot bypass HTML forgery protection' do
    record = draft_unification
    post cashback_unifications_path, params: valid_params, as: :json
    assert_response :not_acceptable
    post confirm_cashback_unification_path(record), as: :json
    assert_response :not_acceptable
    assert record.reload.draft?
  end

  test 'administrator may inspect but cannot confirm another users preview' do
    record = draft_unification
    admin = User.create!(name: 'Admin', email: 'cashback_admin@example.com', password: 'password123', profiles: [Profile.find(Profile::ADMIN)])
    sign_in admin
    get cashback_unification_path(record)
    assert_response :success
    assert_select "form[action='#{confirm_cashback_unification_path(record)}']", count: 0
    post confirm_cashback_unification_path(record)
    assert_response :forbidden
    assert record.reload.draft?
  end

  test 'confirmation requires CSRF token when forgery protection is enabled' do
    record = draft_unification
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    post confirm_cashback_unification_path(record)
    assert_response :unprocessable_entity
    assert record.reload.draft?
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end
end
