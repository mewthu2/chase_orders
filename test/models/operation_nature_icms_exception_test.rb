require 'test_helper'
require_relative '../support/nfe_company_factory'

class OperationNatureIcmsExceptionTest < ActiveSupport::TestCase
  include NfeCompanyFactory

  def setup
    @company = create_nfe_company
    @nature = @company.operation_natures.create!(description: 'Transferência', kind: :transfer, cfop: '?152', final_consumer: false,
                                                 icms_situation: '00', icms_rate: 18, pis_cst: '08', cofins_cst: '08',
                                                 notes: 'Obs geral')
  end

  def add(**attrs)
    @nature.update!(icms_exceptions_attributes: [{ icms_situation: '00', icms_rate: 7 }.merge(attrs)])
    @nature.icms_exceptions.reload.last
  end

  test 'normalizes states and CFOP and matches destination and optional origin' do
    exception = add(destination_states: ['df', '', 'CE'], origin_states: [''], cfop: '6.152')
    assert_equal %w[CE DF], exception.destination_states
    assert_nil exception.origin_states
    assert_equal '6152', exception.cfop
    assert exception.applies_to?(company_state: 'SP', recipient_state: 'DF')

    restricted = add(destination_states: %w[RJ], origin_states: %w[MG])
    assert restricted.applies_to?(company_state: 'MG', recipient_state: 'RJ')
    assert_not restricted.applies_to?(company_state: 'CE', recipient_state: 'RJ')
  end

  test 'nature rules, CFOP and notes follow the matching exception' do
    add(destination_states: %w[DF], origin_states: %w[MG], cfop: '?949', difal: true, fcp_rate: 2, notes: 'Obs DF', fisco_notes: 'Fisco DF')

    rules = @nature.reload.tax_rules(company_state: 'MG', recipient_state: 'DF')
    assert_equal BigDecimal('7'), rules[:icms_rate]
    assert rules[:icms_rate_fixed]
    assert rules[:difal]
    assert_equal BigDecimal('2'), rules[:uf_rates].call('DF')[:fcp]
    assert_equal '6949', @nature.cfop_for(company_state: 'MG', recipient_state: 'DF')
    assert_equal 'Obs geral | Obs DF', @nature.notes_for(company_state: 'MG', recipient_state: 'DF')
    assert_equal 'Fisco DF', @nature.fisco_notes_for(company_state: 'MG', recipient_state: 'DF')

    general = @nature.tax_rules(company_state: 'MG', recipient_state: 'RJ')
    assert_equal BigDecimal('18'), general[:icms_rate]
    assert_nil general[:icms_rate_fixed]
    assert_equal '6152', @nature.cfop_for(company_state: 'MG', recipient_state: 'RJ')
    assert_equal 'Obs geral', @nature.notes_for(company_state: 'MG', recipient_state: 'RJ')
  end

  test 'blank new rows are ignored and rows can be removed' do
    @nature.update!(icms_exceptions_attributes: [{ destination_states: [''], icms_rate: '' }])
    assert_empty @nature.icms_exceptions.reload

    exception = add(destination_states: %w[CE])
    @nature.update!(icms_exceptions_attributes: [{ id: exception.id, _destroy: '1' }])
    assert_empty @nature.icms_exceptions.reload
  end

  test 'rejects invalid states, missing rate and a CSOSN on a Regime Normal nature' do
    assert_not @nature.update(icms_exceptions_attributes: [{ destination_states: %w[XX], icms_rate: 7 }])
    assert_not @nature.update(icms_exceptions_attributes: [{ destination_states: %w[CE], icms_situation: '00', icms_rate: 0 }])
    assert_not @nature.update(icms_exceptions_attributes: [{ destination_states: %w[CE], icms_situation: '102', icms_rate: 0 }])
    assert_includes @nature.errors.full_messages.join, 'use um CST'
  end
end
