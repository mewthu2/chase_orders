require 'test_helper'
require 'minitest/mock'
require_relative '../../support/nfe_company_factory'

# Depois do cancelamento: a nota nova é gerada e assinada (rascunho), sem ir à SEFAZ.
class Nfe::RegeneratorTest < ActiveSupport::TestCase
  include NfeCompanyFactory

  def setup
    @user = User.create!(name: 'Regen', email: 'regen@example.com', password: 'password123')
    @company = create_nfe_company(environment: :producao)
    @nature = create_sale_nature(@company)
    B2bSetting.current.update!(issuer_company: @company, sale_nature: @nature)
    client = Client.create!(responsible_name: 'Fulano', business_name: 'Cliente Ltda', registration: '45.723.174/0001-10', state_registration: '111222333',
                            ie_indicator: 1, street: 'Rua B', number: '20', neighbourhood: 'Bairro', city: 'Belo Horizonte', state: 'MG',
                            zip: '31000-000', city_ibge_code: '3106200', email: 'c@example.com')
    Product.create!(sku: 'SKU-1', shopify_product_name: 'Camiseta', ncm: '61091000')
    @order = B2bOrder.new(kind: :sale, user: @user, client:, payment_method: 'boleto')
    @order.b2b_order_items.build(sku: 'SKU-1', name: 'Camiseta', quantity: 2, price: 10)
    @order.save!
    @canceled = FiscalNote.create!(company: @company, b2b_order: @order, number: 40, series: @company.nfe_series, environment: :producao,
                                   status: :cancelada, access_key: '3' * 44)
    @company.update!(next_nfe_number: 41)
  end

  test 'generates the replacement as a signed draft with a new number and never transmits' do
    draft = Nfe::Transmitter.stub(:call, ->(*, **) { flunk 'não pode emitir' }) { Nfe::Regenerator.call(@canceled) }

    assert draft.rascunho?
    assert draft.producao?
    assert_equal 41, draft.number
    assert draft.xml_available?
    assert draft.emittable?
    assert_equal @order, draft.b2b_order
    assert_not draft.transmittable?, 'rotinas automáticas (que só transmitem assinada) não emitem o rascunho'
  end

  test 'does not replace a production note while the company is in homologation' do
    @company.update!(environment: :homologacao)

    error = assert_raises(Nfe::Regenerator::Error) { Nfe::Regenerator.call(@canceled) }

    assert_match(/está em homologação/, error.message)
    assert_equal 41, @company.reload.next_nfe_number
  end

  test 'only a canceled note can be replaced, and only once while the draft exists' do
    assert_raises(Nfe::Regenerator::Error) { Nfe::Regenerator.call(FiscalNote.new(status: :autorizada)) }
    Nfe::Regenerator.call(@canceled)
    error = assert_raises(Nfe::Regenerator::Error) { Nfe::Regenerator.call(@canceled) }
    assert_match(/ativa/, error.message)
  end
end
