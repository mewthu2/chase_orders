# Puxa NCM, CEST, origem e unidade dos produtos sem NCM no Tiny (conta B2B primeiro, depois as demais).
# Somente leitura no Tiny. Como o Tiny limita as requisições, espera entre as chamadas;
# é idempotente: uma nova execução só trata o que ainda está sem NCM.
class ImportProductsFiscalDataJob < ActiveJob::Base
  queue_as :products

  JOB_NAME = 'Importação de dados fiscais (Tiny)'.freeze
  DEFAULT_THROTTLE_SECONDS = 1.2
  DEFAULT_RATE_LIMIT_WAIT = 60
  PROGRESS_EVERY = 25

  SUMMARY_LABELS = {
    updated: 'Atualizados', no_ncm_in_tiny: 'Sem NCM no Tiny', invalid_ncm: 'NCM inválido no Tiny',
    not_found: 'Não encontrados no Tiny', invalid: 'Inválidos', error: 'Com erro'
  }.freeze

  class << self
    attr_writer :throttle_seconds, :rate_limit_wait

    def throttle_seconds
      @throttle_seconds || DEFAULT_THROTTLE_SECONDS
    end

    def rate_limit_wait
      @rate_limit_wait || DEFAULT_RATE_LIMIT_WAIT
    end

    # Produtos sem NCM que têm ID em pelo menos uma conta Tiny.
    def eligible_scope
      Product.where(ncm: [nil, '']).where(
        "(tiny_2_id IS NOT NULL AND tiny_2_id <> '') OR " \
        "(tiny_lagoa_seca_product_id IS NOT NULL AND tiny_lagoa_seca_product_id <> '') OR " \
        'tiny_bh_shopping_id IS NOT NULL OR tiny_rj_id IS NOT NULL'
      )
    end

    def running?
      motor = Motor.where(job_name: JOB_NAME).order(:id).last
      motor.present? && motor.end_time.blank? && motor.start_time.present? && motor.start_time > 6.hours.ago
    end
  end

  def perform
    scope = self.class.eligible_scope
    total = scope.count
    motor = start_motor
    counts = Hash.new(0)

    scope.find_each.with_index(1) do |product, index|
      result = import(product)
      if result == :rate_limited
        return finish_motor(motor, counts, error: 'O Tiny bloqueou por excesso de acessos. Rode a importação novamente mais tarde; ela continua de onde parou.')
      end

      counts[result] += 1
      motor.update!(step: "#{index}/#{total}") if (index % PROGRESS_EVERY).zero?
      sleep(self.class.throttle_seconds)
    end

    finish_motor(motor, counts)
  rescue StandardError => e
    Rails.logger.error "ImportProductsFiscalDataJob: #{e.class} #{e.message}"
    finish_motor(motor, counts || {}, error: e.message) if motor
  end

  private

  def import(product)
    result = product.import_fiscal_data_from_tiny
    return result unless result == :rate_limited

    sleep(self.class.rate_limit_wait)
    product.import_fiscal_data_from_tiny
  end

  def start_motor
    motor = Motor.find_or_initialize_by(job_name: JOB_NAME)
    motor.update!(start_time: Time.current, end_time: nil, running_time: nil, step: 'started', link: nil)
    motor
  end

  def finish_motor(motor, counts, error: nil)
    summary = SUMMARY_LABELS.filter_map { |key, label| "#{label}: #{counts[key]}" if counts[key].to_i.positive? }
    summary = ['Nenhum produto pendente'] if summary.empty? && error.blank?
    summary << error if error.present?

    motor.update!(end_time: Time.current, step: error.present? ? 'error' : 'finished', link: summary.join(' · '))
  end
end
