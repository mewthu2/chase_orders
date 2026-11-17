# NF-e e XML do Log02. O Tiny 2 não é mais usado: a rodada emite a NF-e no Honey e manda o XML ao Correios
# dos pedidos do Honey já criados lá (HoneyB2bLog).
class SendXmlCorreiosLogJob2 < ActiveJob::Base
  queue_as :correios_b2b
  include SingleRun
  runs_one_at_a_time if: ->(args) { args.first == 'all' }

  def perform(_param = 'all', _att = nil, marker_id = nil)
    HoneyB2bLog.send_pending_xml!
    Attempt.find_by(id: marker_id)&.update(status: :success) if marker_id
  rescue StandardError => e
    Attempt.find_by(id: marker_id)&.update(status: :error, error: e.message) if marker_id
    raise
  end
end
