require 'test_helper'

class ScreenTest < ActiveSupport::TestCase
  # Screen is an in-memory registry; unrelated database fixtures are not needed.
  self.fixture_table_names = []

  test 'cashback unification has a configurable permission' do
    assert_includes Screen::GROUPS['Outros'], :cashback_unifications
    assert_equal 'Cupons de Cashback', Screen.label(:cashback_unifications)
  end

  test 'keys returns all screen keys as strings' do
    assert_includes Screen.keys, 'users_management'
    assert_includes Screen.keys, 'marketing_tasks'
    assert_equal Screen::DEFINITIONS.size, Screen.keys.size
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

  test 'companies and fiscal_notes screens belong to the Pedidos B2B group' do
    assert_includes Screen::GROUPS['Pedidos B2B'], :companies
    assert_includes Screen::GROUPS['Pedidos B2B'], :fiscal_notes
    assert_equal 'Empresas', Screen::DEFINITIONS[:companies]
    assert_equal 'Notas Fiscais', Screen::DEFINITIONS[:fiscal_notes]
  end

  test 'transfer_locations screen belongs to the Produtos group' do
    assert_includes Screen::GROUPS['Produtos'], :transfer_locations
    refute_includes Screen::GROUPS['Pedidos B2B'], :transfer_locations
  end

  test 'stock reservation screens belong to their Correios groups' do
    assert_includes Screen::GROUPS['Correios B2B'], :stock_reservations_b2b
    assert_includes Screen::GROUPS['Correios B2C'], :stock_reservations_b2c
    assert_equal 'Reservas de Estoque B2B', Screen.label(:stock_reservations_b2b)
    assert_equal 'Reservas de Estoque B2C', Screen.label(:stock_reservations_b2c)
  end

  test 'b2b catalogs screen belongs to the Pedidos B2B group' do
    assert_includes Screen::GROUPS['Pedidos B2B'], :b2b_catalogs
    assert_equal 'Catálogos B2B', Screen.label(:b2b_catalogs)
  end
end
