# Criação no Correios dos pedidos do Log02. O Tiny 2 não é mais usado: a rodada só cria os pedidos do
# Honey aprovados em Log02 › Pedidos p/ Aprovar (HoneyB2bLog).
class CreateCorreiosLogOrdersJob2 < ActiveJob::Base
  include SingleRun
  runs_one_at_a_time if: ->(args) { args.first == 'all' }

  queue_as :correios_b2b

  def perform(_param = 'all', _order = nil, marker_id = nil)
    HoneyB2bLog.create_pending!
    Attempt.find_by(id: marker_id)&.update(status: :success) if marker_id
  rescue StandardError => e
    Attempt.find_by(id: marker_id)&.update(status: :error, error: e.message) if marker_id
    raise
  end
end
