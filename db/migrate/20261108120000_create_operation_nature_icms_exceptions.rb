# Exceções do ICMS por natureza de operação, no molde do Tiny: para certas UFs de destino (e, opcionalmente,
# certas UFs do emitente) a nota usa outra CST, CFOP, alíquota, DIFAL, FCP e observações.
# Também cadastra as exceções que o Tiny tem na natureza de transferência (CE, RJ/RS/SP e DF). Seguro para rodar
# a qualquer momento: só cria a tabela se faltar e só insere as exceções se a natureza ainda não tiver nenhuma.
class CreateOperationNatureIcmsExceptions < ActiveRecord::Migration[7.2]
  class Nature < ActiveRecord::Base
    self.table_name = 'operation_natures'
  end

  class IcmsException < ActiveRecord::Base
    self.table_name = 'operation_nature_icms_exceptions'
  end

  TRANSFER_NOTE = 'Remessa em transferência de mercadoria entre estabelecimentos da mesma titularidade, nos termos ' \
                  'do art. 12, §4º da LC 87/96. Crédito do ICMS transferido ao estabelecimento destinatário.'

  # Regras do Tiny (conta MG): por isso valem só para emitente em MG.
  TINY_TRANSFER_EXCEPTIONS = [
    { destination_states: %w[CE], icms_rate: 7, difal: false, notes: TRANSFER_NOTE },
    { destination_states: %w[RJ RS SP], icms_rate: 12, difal: false, notes: TRANSFER_NOTE },
    { destination_states: %w[DF], icms_rate: 7, difal: true, notes: nil }
  ].freeze

  def up
    unless table_exists?(:operation_nature_icms_exceptions)
      create_table :operation_nature_icms_exceptions do |t|
        t.references :operation_nature, null: false, foreign_key: true
        t.json :destination_states, null: false
        t.json :origin_states
        t.string :icms_situation, null: false, default: '00'
        t.string :cfop
        t.decimal :icms_rate, precision: 5, scale: 2, null: false, default: 0
        t.boolean :difal, null: false, default: false
        t.decimal :fcp_rate, precision: 5, scale: 2, null: false, default: 0
        t.text :notes
        t.text :fisco_notes
        t.timestamps
      end
    end

    seed_transfer_exceptions
  end

  def down
    drop_table :operation_nature_icms_exceptions, if_exists: true
  end

  private

  def seed_transfer_exceptions
    Nature.reset_column_information
    IcmsException.reset_column_information
    Nature.where(kind: 1, cfop: '?152', icms_situation: '00').find_each do |nature|
      next if IcmsException.exists?(operation_nature_id: nature.id)

      TINY_TRANSFER_EXCEPTIONS.each do |rule|
        IcmsException.create!(rule.merge(operation_nature_id: nature.id, origin_states: %w[MG], icms_situation: '00',
                                         cfop: '6152', fcp_rate: 0))
      end
    end
  end
end
