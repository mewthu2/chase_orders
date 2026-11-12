require 'test_helper'

class SingleRunTest < ActiveJob::TestCase
  class MemoryStore
    attr_reader :data

    def initialize = @data = {}
    def read(key) = @data[key]
    def refresh(_key, _expected, _ttl) = 1

    def swap(key, expected, value, _ttl)
      return false unless @data[key] == expected

      @data[key] = value
      true
    end

    def release(key, expected) = (@data.delete(key) if @data[key] == expected)
  end

  class BrokenStore
    def read(_key) = raise(Redis::CannotConnectError, 'sem redis')
  end

  class RoutineJob < ActiveJob::Base
    include SingleRun
    runs_one_at_a_time if: ->(args) { args.first == 'all' }

    cattr_accessor :runs, default: 0
    cattr_accessor :inside

    def perform(param, _att = nil, _marker_id = nil)
      self.class.runs += 1
      self.class.inside&.call
    end
  end

  def setup
    @store = MemoryStore.new
    @queued = []
    SingleRun.store = @store
    SingleRun.queued_check = ->(job_id) { @queued.include?(job_id) }
    RoutineJob.runs = 0
    RoutineJob.inside = nil
  end

  def teardown
    SingleRun.store = SingleRun::RedisStore.new
  end

  test 'a second copy does not enter the queue while the first is waiting' do
    first = RoutineJob.perform_later('all')
    @queued << first.job_id

    assert first
    assert_equal false, RoutineJob.perform_later('all')
    assert_equal 1, enqueued_jobs.size
  end

  test 'single-item mode is never locked' do
    RoutineJob.perform_later('all')
    RoutineJob.perform_later('one', 1)
    RoutineJob.perform_later('one', 2)

    assert_equal 3, enqueued_jobs.size
  end

  test 'a run that starts while another is running is skipped and closes its screen marker' do
    marker = Attempt.create!(kinds: :send_xml, status: :processing)
    RoutineJob.inside = -> { RoutineJob.perform_now('all', nil, marker.id) }

    RoutineJob.perform_now('all')

    assert_equal 1, RoutineJob.runs
    assert marker.reload.success?
    assert_equal SingleRun::SKIPPED_MESSAGE, marker.message
  end

  test 'the lock is released when the run ends, also when it fails' do
    RoutineJob.perform_now('all')
    RoutineJob.inside = -> { raise 'falhou' }
    assert_raises(RuntimeError) { RoutineJob.perform_now('all') }
    RoutineJob.inside = nil
    RoutineJob.perform_now('all')

    assert_equal 3, RoutineJob.runs
    assert_empty @store.data
  end

  test 'the queued copy runs holding its own lock' do
    job = RoutineJob.perform_later('all')
    @queued << job.job_id

    perform_enqueued_jobs

    assert_equal 1, RoutineJob.runs
    assert_empty @store.data
  end

  test 'a waiting lock whose job left the queue is stale and is taken over' do
    RoutineJob.perform_later('all') # dono não está em @queued: a fila foi limpa à mão
    clear_enqueued_jobs

    assert RoutineJob.perform_later('all')
    assert_equal 1, enqueued_jobs.size
  end

  test 'a running lock is respected even if the job is not in the queue' do
    @store.data['single_run:SingleRunTest::RoutineJob'] = 'outro-job|running'

    RoutineJob.perform_now('all')

    assert_equal 0, RoutineJob.runs
  end

  test 'without redis the job runs anyway' do
    SingleRun.store = BrokenStore.new

    RoutineJob.perform_now('all')

    assert_equal 1, RoutineJob.runs
  end
end
