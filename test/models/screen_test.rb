require 'test_helper'

class ScreenTest < ActiveSupport::TestCase
  test 'keys returns all screen keys as strings' do
    assert_includes Screen.keys, 'users_management'
    assert_includes Screen.keys, 'marketing_tasks'
    assert_equal 8, Screen.keys.size
  end

  test 'label returns the business name for a known key' do
    assert_equal 'Gerenciar Usuários', Screen.label(:users_management)
    assert_equal 'Gerenciar Usuários', Screen.label('users_management')
  end

  test 'label returns nil for an unknown key' do
    assert_nil Screen.label(:not_a_real_screen)
  end

  test 'options_for_select pairs label with key' do
    assert_includes Screen.options_for_select, ['Pedidos', 'orders']
  end
end
