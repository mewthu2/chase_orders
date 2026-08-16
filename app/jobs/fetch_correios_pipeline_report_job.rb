class FetchCorreiosPipelineReportJob < ApplicationJob
  queue_as :default

  RESULT_TTL = 5.minutes.to_i
  PROCESSING_TTL = 3.minutes.to_i

  # Etapa seguinte de cada estágio do funil, na ordem real de negócio:
  # create_correios_order -> emission_invoice -> send_xml -> get_tracking.
  # (kinds=1 é send_xml e kinds=2 é emission_invoice — a ordem dos valores do enum
  # não é a ordem em que as etapas acontecem.)
  NEXT_KIND = {
    'invoice' => 'emission_invoice',
    'xml' => 'send_xml',
    'tracking' => 'get_tracking'
  }.freeze

  PRIOR_STAGE = { 'xml' => 'invoice', 'tracking' => 'xml' }.freeze

  IDLE_THRESHOLD = 6.hours

  def self.result_key(period) = "correios_pipeline:result:#{period}"
  def self.processing_key(period) = "correios_pipeline:processing:#{period}"

  def perform(period)
    report = build_report(period)
    $redis.set(self.class.result_key(period), report.to_json, ex: RESULT_TTL)
  rescue StandardError => e
    $redis.set(self.class.result_key(period), { error: e.message }.to_json, ex: RESULT_TTL)
  ensure
    $redis.del(self.class.processing_key(period))
  end

  private

  def build_report(period)
    rows = fetch_pipeline_rows(period_since(period))

    counts = { 'invoice' => 0, 'xml' => 0, 'tracking' => 0, 'completed' => 0 }
    rows.each { |row| counts[row['current_stage']] += 1 }

    attention = build_attention_rows(rows.reject { |row| row['current_stage'] == 'completed' })

    { counts:, attention: }
  end

  def period_since(period)
    case period
    when 'today' then Date.current.beginning_of_day
    when '7' then 7.days.ago
    when '90' then 90.days.ago
    else 30.days.ago
    end
  end

  def fetch_pipeline_rows(since)
    # EXISTS/NOT EXISTS dentro do WHERE de cada CTE (mesmo padrão de
    # DashboardController#prepare_tracking_data_optimized) em vez de dentro de um CASE no
    # SELECT: só assim o MySQL consegue otimizar como semi-join. Um EXISTS dentro do CASE do
    # SELECT vira subquery correlacionada linha a linha e trava a página — attempts não tem
    # índice em order_correios_id, e kinds=1/send_xml sozinho passa de 1.7M linhas.
    sql = <<-SQL
      WITH successful_orders AS (
        SELECT tiny_order_id, order_correios_id, MAX(created_at) AS order_created_at
        FROM attempts
        WHERE kinds = 0 AND status = 2 AND created_at >= :since
        GROUP BY tiny_order_id, order_correios_id
      ),
      invoice_pending AS (
        SELECT so.tiny_order_id, so.order_correios_id
        FROM successful_orders so
        WHERE NOT EXISTS (
          SELECT 1 FROM attempts a
          WHERE a.order_correios_id = so.order_correios_id AND a.kinds = 2 AND a.status = 2
        )
      ),
      xml_pending AS (
        SELECT so.tiny_order_id, so.order_correios_id
        FROM successful_orders so
        WHERE EXISTS (
          SELECT 1 FROM attempts a
          WHERE a.order_correios_id = so.order_correios_id AND a.kinds = 2 AND a.status = 2
        )
        AND NOT EXISTS (
          SELECT 1 FROM attempts a
          WHERE a.order_correios_id = so.order_correios_id AND a.kinds = 1 AND a.status = 2
        )
      ),
      tracking_pending AS (
        SELECT so.tiny_order_id, so.order_correios_id
        FROM successful_orders so
        WHERE EXISTS (
          SELECT 1 FROM attempts a
          WHERE a.order_correios_id = so.order_correios_id AND a.kinds = 1 AND a.status = 2
        )
        AND NOT EXISTS (
          SELECT 1 FROM attempts a
          WHERE a.order_correios_id = so.order_correios_id AND a.kinds = 3 AND a.status = 2
        )
      )
      SELECT
        so.tiny_order_id,
        so.order_correios_id,
        so.order_created_at,
        CASE
          WHEN ip.tiny_order_id IS NOT NULL THEN 'invoice'
          WHEN xp.tiny_order_id IS NOT NULL THEN 'xml'
          WHEN tp.tiny_order_id IS NOT NULL THEN 'tracking'
          ELSE 'completed'
        END AS current_stage
      FROM successful_orders so
      LEFT JOIN invoice_pending ip ON ip.tiny_order_id = so.tiny_order_id
      LEFT JOIN xml_pending xp ON xp.tiny_order_id = so.tiny_order_id
      LEFT JOIN tracking_pending tp ON tp.tiny_order_id = so.tiny_order_id
      ORDER BY so.order_created_at DESC;
    SQL

    ActiveRecord::Base.connection.exec_query(
      ActiveRecord::Base.sanitize_sql_array([sql, { since: }])
    ).to_a
  end

  def build_attention_rows(pending_rows)
    return [] if pending_rows.empty?

    tiny_order_ids = pending_rows.map { |row| row['tiny_order_id'] }

    # Busca por tiny_order_id, não order_correios_id: attempts não tem índice em
    # order_correios_id, e com a baixíssima seletividade do índice de kinds (só ~6 valores
    # distintos em 1.6M+ linhas) o MySQL escolhe um plano com centenas de milhares de leituras
    # aleatórias linha a linha — 60s+ até pra 40 ids. tiny_order_id tem um índice bem mais
    # seletivo (~25 mil valores distintos) e resolve a mesma busca em ~2s.
    relevant_attempts = Attempt.where(tiny_order_id: tiny_order_ids, kinds: NEXT_KIND.values)
                                .order(created_at: :desc)
                                .group_by(&:tiny_order_id)

    pending_rows.filter_map do |row|
      stage = row['current_stage']
      attempts_for_order = relevant_attempts[row['tiny_order_id']] || []

      next_kind = NEXT_KIND[stage]
      last_attempt = attempts_for_order.find { |a| a.kinds == next_kind }

      entry_kind = NEXT_KIND[PRIOR_STAGE[stage]]
      entry_attempt = entry_kind && attempts_for_order.find { |a| a.kinds == entry_kind && a.success? }
      stage_entered_at = entry_attempt&.created_at || row['order_created_at']

      if last_attempt.nil?
        next if Time.current - stage_entered_at < IDLE_THRESHOLD

        reason = 'idle'
        last_activity_at = stage_entered_at
        # Mostra a mensagem da tentativa que empurrou o pedido pra essa etapa (quando existir):
        # é comum um "sucesso" da Shopify/Tiny vir com uma mensagem de erro escondida (ex: "pedido
        # já faturado"), então isso costuma explicar por que a próxima etapa nunca aconteceu.
        message = entry_attempt&.message
        attempt_id = nil
      elsif last_attempt.fail? || last_attempt.error?
        reason = 'error'
        last_activity_at = last_attempt.created_at
        message = last_attempt.message.presence || last_attempt.error
        attempt_id = last_attempt.id
      elsif Time.current - last_attempt.created_at >= IDLE_THRESHOLD
        reason = 'idle'
        last_activity_at = last_attempt.created_at
        message = last_attempt.message
        attempt_id = last_attempt.id
      else
        next
      end

      {
        tiny_order_id: row['tiny_order_id'],
        current_stage: stage,
        reason:,
        message:,
        last_activity_at:,
        attempt_id:
      }
    end.sort_by { |row| row[:last_activity_at] }
       .map { |row| row.merge(last_activity_at: row[:last_activity_at].strftime('%d/%m/%Y %H:%M')) }
  end
end
