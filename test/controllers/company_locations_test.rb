require 'test_helper'
require_relative '../support/nfe_company_factory'

# Loja de cada empresa: define quem emite e quem recebe a nota de transferência na Transferência Interna.
class CompanyLocationsTest < ActionDispatch::IntegrationTest
  include NfeCompanyFactory

  def setup
    admin = User.create!(name: 'Admin Lojas', email: 'admin_lojas_empresa@example.com', password: 'password123')
    admin.profiles << Profile.find(Profile::ADMIN)
    sign_in admin
    @company = create_nfe_company
    @other = create_nfe_company(legal_name: 'Chase Rio Ltda', cnpj: '45.723.174/0001-10', state_registration: '87654321')
    @bh = Location.create!(slug: 'bh_shopping', name: 'BH Shopping', shopify_location_id: '222', company: @company)
    @rj = Location.create!(slug: 'rj', name: 'Barra Shopping', shopify_location_id: '333', company: @other)
  end

  test 'the form picks one store; choosing a store of another company moves it and frees the previous one' do
    get edit_company_path(@company)
    assert_select '#loja select#company_location_id option[selected]', text: 'BH Shopping'
    assert_select '#loja option', text: 'Barra Shopping (hoje: Chase Rio Ltda)'
    assert_select '.tiny-import', count: 0

    patch company_path(@company), params: { company: { legal_name: @company.legal_name, location_id: @rj.id } }

    assert_redirected_to companies_path
    assert_equal @company, @rj.reload.company
    assert_nil @bh.reload.company
    assert_nil @other.reload.location
  end

  test 'choosing no store unlinks it and the list shows the store of each company' do
    patch company_path(@company), params: { company: { legal_name: @company.legal_name, location_id: '' } }
    assert_nil @bh.reload.company

    get companies_path
    assert_select 'td', text: 'Barra Shopping'
  end

  test 'a store cannot belong to two companies' do
    refute @bh.update(company: @other)
    assert_includes @bh.errors.full_messages.to_sentence, 'já tem outra loja'
  end
end
