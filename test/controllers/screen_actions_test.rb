require 'test_helper'

# Permissão por ação: o perfil libera, em cada tela, só algumas ações (ver, criar, editar...).
class ScreenActionsTest < ActionDispatch::IntegrationTest
  def user_with(actions, locations: [])
    profile = Profile.create!(name: "Perfil #{SecureRandom.hex(3)}", allowed_locations: locations)
    profile.update!(screen_actions: actions)
    User.create!(name: 'Pessoa', email: "p#{SecureRandom.hex(3)}@example.com", password: 'password123').tap do |user|
      user.profiles << profile
    end
  end

  test 'view-only profile opens the list but cannot open the create form' do
    sign_in user_with({ 'carriers' => 'V' })

    get carriers_path
    assert_response :success

    get new_carrier_path
    assert_redirected_to root_path
    assert_match(/não permite criar em Transportadoras/, flash[:alert])
  end

  test 'a profile with Criar can open the create form' do
    sign_in user_with({ 'carriers' => 'VC' })

    get new_carrier_path
    assert_response :success
  end

  test 'actions combine across profiles' do
    user = user_with({ 'carriers' => 'V' })
    extra = Profile.create!(name: 'Extra')
    extra.update!(screen_actions: { 'carriers' => 'D' })
    user.profiles << extra

    assert user.can?(:carriers, 'D')
    refute user.can?(:carriers, 'C')
    assert_equal 'VD', user.actions_for(:carriers)
  end

  test 'store supply has its own permission, separate from wholesale orders' do
    sign_in user_with({ 'store_supply' => 'V' })

    get stock_transfers_path
    assert_response :success

    get b2b_orders_path
    assert_redirected_to root_path
  end

  test 'profile locations add to the user locations' do
    user = user_with({ 'stock_corrections' => 'V' }, locations: ['rj'])
    user.update!(allowed_locations: ['bh_shopping'])

    assert_equal %w[bh_shopping rj], user.reload.allowed_location_keys.sort
    assert_equal ['bh_shopping'], user.own_location_keys
  end

  test 'every user opens tickets; deleting one depends on the profile' do
    user = user_with({})
    assert user.can?(:tickets, 'C')
    refute user.can?(:tickets, 'D')

    user.profiles.first.update!(screen_actions: { 'tickets' => 'D' })
    assert user.reload.can?(:tickets, 'D')
  end

  test 'only admins edit profiles' do
    sign_in user_with({ 'users_management' => 'VCED' })

    get profiles_path
    assert_redirected_to root_path
  end

  test 'a non-admin user manager cannot pick profiles when creating a user' do
    sign_in user_with({ 'users_management' => 'VCED' })

    post users_path, params: { user: { name: 'Novo', email: 'novo_sem_admin@example.com', password: 'password123',
                                       password_confirmation: 'password123', profile_ids: [Profile::ADMIN] } }

    created = User.find_by!(email: 'novo_sem_admin@example.com')
    assert_equal [Profile::USER], created.profile_ids
  end
end
