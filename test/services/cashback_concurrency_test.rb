require 'test_helper'
require_relative '../support/cashback_factory'

class CashbackConcurrencyTest < ActiveSupport::TestCase
  include CashbackFactory
  self.fixture_table_names = []
  self.use_transactional_tests = false

  setup { setup_cashback }
  teardown do
    travel_back
    ids = CashbackUnification.where(user: @user).pluck(:id)
    CashbackUnificationSource.where(cashback_unification_id: ids).delete_all
    CashbackUnification.where(id: ids).delete_all
    Log.where(user: @user).delete_all
    @user.destroy!
    @customer.destroy!
  end

  test 'two database connections cannot consume a source while its operation is running' do
    first = draft_unification
    overlapping = draft_unification
    entered = Queue.new
    release = Queue.new
    @gateway.before_deactivate = lambda do |id|
      if id.end_with?('/1')
        entered << true
        release.pop
      end
    end
    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        unify(CashbackUnification.find(first.id))
      end
    end
    Timeout.timeout(10) { entered.pop }
    assert first.reload.processing?
    assert_equal 2, first.sources.count, 'claims must be committed before any remote mutation'
    assert_raises(Cashback::Unify::Error) { unify(overlapping) }
    assert_raises(Cashback::Unify::Error) { unify(CashbackUnification.find(first.id)) }
    release << true
    Timeout.timeout(10) { worker.value }
    assert first.reload.completed?
    assert_equal 1, @gateway.inputs.size
    assert_equal [:deactivate, :deactivate, :create], @gateway.writes.map(&:first)
  ensure
    release << true if release
    worker&.join(10)
  end
end
