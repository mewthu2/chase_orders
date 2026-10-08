require 'test_helper'

class StockReservationRefreshTest < ActiveSupport::TestCase
  test 'for creates one row per account and reuses it' do
    first = StockReservationRefresh.for(:b2b)
    assert_equal first, StockReservationRefresh.for('b2b')
    refute_equal first, StockReservationRefresh.for(:b2c)
    assert_equal 'idle', first.status
  end

  test 'next_refresh_at is ten minutes after the last refresh' do
    refresh = StockReservationRefresh.for(:b2b)
    assert_nil refresh.next_refresh_at

    time = Time.zone.parse('2026-10-08 10:00')
    refresh.update!(last_refreshed_at: time)
    assert_equal time + 10.minutes, refresh.next_refresh_at
  end

  test 'running_recently? ignores a run stuck for more than five minutes' do
    refresh = StockReservationRefresh.for(:b2b)
    refresh.update!(status: 'running')
    assert refresh.running_recently?

    refresh.update_columns(updated_at: 6.minutes.ago)
    refute refresh.running_recently?
  end
end
