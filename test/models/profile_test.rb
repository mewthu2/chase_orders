require 'test_helper'

class ProfileTest < ActiveSupport::TestCase
  def setup
    @profile = Profile.create!(name: 'Perfil de Teste')
  end

  test 'can_access? is false with no permissions' do
    refute @profile.can_access?('orders')
  end

  test 'can_access? is true once the screen is granted' do
    @profile.screen_permissions.create!(screen_key: 'orders')
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

  test 'destroying a profile destroys its screen_permissions' do
    @profile.screen_permissions.create!(screen_key: 'orders')
    permission_id = @profile.screen_permissions.first.id
    @profile.destroy
    assert_nil ScreenPermission.find_by(id: permission_id)
  end
end
