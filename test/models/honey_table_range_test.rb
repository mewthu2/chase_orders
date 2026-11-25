require 'test_helper'

# Intervalo "de tal dia a tal dia" escolhido no calendário dos filtros de data (mês e período).
class HoneyTableRangeTest < ActiveSupport::TestCase
  test 'parses a day range, in any order, from the start of the first day to the end of the last' do
    range = HoneyTable.parse_range('2026-11-20..2026-11-03')

    assert_equal Time.zone.parse('2026-11-03 00:00:00'), range.begin
    assert_equal Time.zone.parse('2026-11-20').end_of_day, range.end
    assert_equal '03/11/2026 a 20/11/2026', HoneyTable.range_label('2026-11-03..2026-11-20')
    assert_equal '05/11/2026', HoneyTable.range_label('2026-11-05..2026-11-05')
    assert_equal '03/11/2026 a 20/11/2026', HoneyTable.month_label('2026-11-03..2026-11-20')
  end

  test 'ignores values that are not a valid range' do
    assert_nil HoneyTable.parse_range('2026-11')
    assert_nil HoneyTable.parse_range('2026-13-01..2026-13-05')
    assert_nil HoneyTable.parse_range('30')
  end

  test 'the period filter keeps only the rows inside the chosen days' do
    rows = [{ n: 1, dt: Time.zone.parse('2026-11-02 23:59') }, { n: 2, dt: Time.zone.parse('2026-11-03 00:10') },
            { n: 3, dt: Time.zone.parse('2026-11-20 23:00') }, { n: 4, dt: Time.zone.parse('2026-11-21 00:01') }]
    table = HoneyTable.new({ 'per' => '2026-11-03..2026-11-20' }, rows:, cols: [{ k: :n }, { k: :dt, t: :dt }],
                                                                   filters: [{ id: :per, type: :period, label: 'Período', col: :dt }])

    assert_equal [2, 3], table.matching.map { |r| r[:n] }
    assert_includes table.filter_options(table.filters.first), ['2026-11-03..2026-11-20', '03/11/2026 a 20/11/2026']
  end
end
