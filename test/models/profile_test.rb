require 'test_helper'

class ProfileTest < ActiveSupport::TestCase
  def setup
    @profile = Profile.create!(name: 'Perfil de Teste')
  end

  test 'can_access? is false with no permissions' do
    refute @profile.can_access?('orders')
  end

  test 'can_access? is true once the screen is granted' do
    @profile.screen_permissions.create!(screen_key: 'orders', actions: 'VP')
    assert @profile.can_access?('orders')
    assert @profile.can_access?(:orders)
  end

  test 'screen_keys= replaces the whole permission set' do
    @profile.screen_keys = %w[orders customers]
    @profile.save!
    assert_equal %w[customers orders], @profile.reload.screen_keys.sort

    @profile.screen_keys = ['orders']
    @profile.save!
    assert_equal ['orders'], @profile.reload.screen_keys
  end

  test 'screen_keys= ignores blank and unknown keys' do
    @profile.screen_keys = ['orders', '', nil, 'not_a_real_screen']
    @profile.save!
    assert_equal ['orders'], @profile.reload.screen_keys
  end

  test 'screen_keys= grants every action the screen offers' do
    @profile.update!(screen_keys: ['b2b_orders'])
    assert_equal 'VCEXDP', @profile.actions_for('b2b_orders')
    assert @profile.can?('b2b_orders', 'X')
  end

  test 'screen_actions= keeps chosen actions, adds Ver and drops empty screens' do
    @profile.update!(screen_actions: { 'carriers' => 'CD', 'orders' => '', 'nope' => 'V' })
    assert_equal ['carriers'], @profile.reload.screen_keys
    assert_equal 'VCD', @profile.actions_for('carriers')
    refute @profile.can?('carriers', 'E')
  end

  test 'tickets: every profile opens and answers; deleting depends on the profile' do
    assert @profile.can?('tickets', 'V')
    assert @profile.can?('tickets', 'C')
    refute @profile.can?('tickets', 'D')
  end

  test 'rejects unknown locations' do
    @profile.allowed_locations = ['rj', 'atlantida']
    refute @profile.valid?
    assert_includes @profile.errors[:allowed_locations].join, 'atlantida'
  end

  test 'destroying a profile destroys its screen_permissions' do
    @profile.screen_permissions.create!(screen_key: 'orders')
    permission_id = @profile.screen_permissions.first.id
    @profile.destroy
    assert_nil ScreenPermission.find_by(id: permission_id)
  end
end
