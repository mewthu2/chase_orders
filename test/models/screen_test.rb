require 'test_helper'

class ScreenTest < ActiveSupport::TestCase
  # Screen is an in-memory registry; unrelated database fixtures are not needed.
  self.fixture_table_names = []

  test 'every screen belongs to a known area and only offers known actions' do
    Screen::DEFINITIONS.each do |key, definition|
      assert_includes Screen::AREAS.keys, definition[:area], key
      assert definition[:acts].start_with?('V'), "#{key} precisa oferecer Ver"
      assert_empty definition[:acts].chars - Screen::ACTION_LETTERS, key
    end
  end

  test 'keys returns all screen keys as strings' do
    assert_includes Screen.keys, 'users_management'
    assert_includes Screen.keys, 'clients'
    assert_includes Screen.keys, 'store_supply'
    assert_equal Screen::DEFINITIONS.size, Screen.keys.size
  end

  test 'label returns the business name for a known key' do
    assert_equal 'Gerenciar Usuários', Screen.label(:users_management)
    assert_equal 'Gerenciar Usuários', Screen.label('users_management')
    assert_nil Screen.label(:not_a_real_screen)
  end

  test 'normalize_actions keeps only offered actions, in order, and always adds Ver' do
    assert_equal 'VP', Screen.normalize_actions(:orders, 'PXC')
    assert_equal 'VCE', Screen.normalize_actions(:clients, 'EC')
    assert_equal '', Screen.normalize_actions(:orders, '')
    assert_equal '', Screen.normalize_actions(:orders, 'Z')
  end

  test 'by_area groups the screens in menu order' do
    grouped = Screen.by_area
    assert_equal Screen::AREAS.keys, grouped.keys
    assert_includes grouped['adm'].map(&:first), 'fiscal_notes'
    assert_includes grouped['loja'].map(&:first), 'stock_withdrawals'
  end

  test 'location screens are flagged' do
    assert Screen.location?(:stock_corrections)
    refute Screen.location?(:orders)
    assert_equal 'VCE', Screen.base_actions(:tickets)
  end
end
