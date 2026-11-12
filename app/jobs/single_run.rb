# Rotina que não pode rodar de novo antes de a anterior acabar (os jobs que o Heroku Scheduler dispara).
# Com o worker de uma thread só, uma rodada lenta (ex.: o envio de XML) fazia o Scheduler empilhar
# cópias de tudo atrás dela — chegou a 333 jobs e 19 h de atraso. Agora cada rotina tem uma trava no Redis:
#
# - ao enfileirar: se já existe uma igual na fila ou rodando, esta não entra na fila;
# - ao executar (também no perform_now do Scheduler): se outra está rodando, esta é ignorada.
#
# Enquanto roda, a trava é renovada a cada minuto e expira em 10 min se o processo morrer. A trava de
# "na fila" dura até 12 h, mas é descartada se o job dono não estiver mais na fila (ex.: fila limpa à mão).
# Se o Redis falhar, o job roda normalmente (melhor rodar repetido do que parar tudo).
#
#   class SendXmlCorreiosLogJob < ActiveJob::Base
#     include SingleRun
#     runs_one_at_a_time if: ->(args) { args.first == 'all' }
#   end
module SingleRun
  extend ActiveSupport::Concern

  QUEUED_TTL = 12.hours.to_i
  RUNNING_TTL = 10.minutes.to_i
  HEARTBEAT = 60
  SKIPPED_MESSAGE = 'Ignorada: já havia uma execução desta rotina em andamento.'.freeze

  # Trava no Redis do Sidekiq. Troca e liberação atômicas (só mexe se o valor for o esperado).
  class RedisStore
    SWAP = <<~LUA.freeze
      local cur = redis.call('GET', KEYS[1])
      if (cur == false and ARGV[1] == '') or cur == ARGV[1] then
        redis.call('SET', KEYS[1], ARGV[2], 'EX', ARGV[3])
        return 1
      end
      return 0
    LUA
    RELEASE = "if redis.call('GET', KEYS[1]) == ARGV[1] then return redis.call('DEL', KEYS[1]) end return 0".freeze
    REFRESH = "if redis.call('GET', KEYS[1]) == ARGV[1] then return redis.call('EXPIRE', KEYS[1], ARGV[2]) end return 0".freeze

    def read(key) = Sidekiq.redis { |c| c.call('GET', key) }
    def swap(key, expected, value, ttl) = Sidekiq.redis { |c| c.call('EVAL', SWAP, 1, key, expected.to_s, value, ttl) } == 1
    def release(key, expected) = Sidekiq.redis { |c| c.call('EVAL', RELEASE, 1, key, expected) }
    def refresh(key, expected, ttl) = Sidekiq.redis { |c| c.call('EVAL', REFRESH, 1, key, expected, ttl) }
  end

  mattr_accessor :store, default: RedisStore.new

  # O job dono da trava "na fila" ainda está esperando no Sidekiq? Na dúvida, sim (não rouba a trava).
  mattr_accessor :queued_check, default: lambda { |job_id|
    begin
      require 'sidekiq/api'
      sets = Sidekiq::Queue.all + [Sidekiq::ScheduledSet.new, Sidekiq::RetrySet.new]
      sets.any? { |set| set.any? { |j| j.args.first.is_a?(Hash) && j.args.first['job_id'] == job_id } }
    rescue StandardError
      true
    end
  }

  class_methods do
    # if: só trava quando os argumentos casam (ex.: modo 'all'); key: separa travas por argumento.
    def runs_one_at_a_time(if: ->(_args) { true }, key: ->(_args) { nil })
      condition = binding.local_variable_get(:if)
      key_proc = key
      define_method(:single_run_applies?) { condition.call(arguments) }
      define_method(:single_run_key) { ['single_run', self.class.name, key_proc.call(arguments)].compact.join(':') }

      before_enqueue do |job|
        next unless job.single_run_applies?
        next if job.single_run_acquire(:queued)

        job.single_run_skipped('não entrou na fila')
        throw :abort
      end

      around_perform do |job, block|
        next block.call unless job.single_run_applies?

        if job.single_run_acquire(:running)
          job.single_run_hold(&block)
        else
          job.single_run_skipped('não foi executada')
        end
      end
    end
  end

  def single_run_acquire(state)
    value = "#{job_id}|#{state}"
    ttl = state == :queued ? QUEUED_TTL : RUNNING_TTL
    current = store.read(single_run_key)
    return store.swap(single_run_key, nil, value, ttl) if current.nil?

    owner, mode = current.split('|', 2)
    return store.swap(single_run_key, current, value, ttl) if owner == job_id
    return store.swap(single_run_key, current, value, ttl) if mode == 'queued' && !queued_check.call(owner)

    false
  rescue StandardError => e
    Rails.logger.warn("[SingleRun] #{self.class.name}: trava indisponível (#{e.class}: #{e.message}); executando mesmo assim")
    true
  end

  def single_run_hold
    owner = "#{job_id}|running"
    heartbeat = Thread.new do
      loop do
        sleep HEARTBEAT
        store.refresh(single_run_key, owner, RUNNING_TTL)
      rescue StandardError
        nil
      end
    end
    yield
  ensure
    heartbeat&.kill
    begin
      store.release(single_run_key, owner)
    rescue StandardError
      nil
    end
  end

  # Rodada ignorada: avisa no log e fecha o marcador da tela (3º argumento), senão ele fica "rodando".
  def single_run_skipped(what)
    puts "[SingleRun] #{self.class.name} #{arguments.inspect} #{what}: já existe uma igual na fila ou rodando."
    marker_id = arguments[2]
    Attempt.find_by(id: marker_id)&.update(status: :success, message: SKIPPED_MESSAGE) if marker_id.is_a?(Integer)
  rescue StandardError
    nil
  end
end
