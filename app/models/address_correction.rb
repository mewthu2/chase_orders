# Correção de endereço guardada no Honey para um pedido do Tiny (ex.: bairro que veio vazio).
# Vale para o que o Honey envia (pedido dos Correios). A nota fiscal é emitida pelo Tiny com a cópia
# do endereço que ele guardou e a API não permite alterá-la; nesse caso o pedido fica
# "aguardando correção da nota no Tiny" até alguém corrigir lá e avisar o Honey.
class AddressCorrection < ApplicationRecord
  # Nome do campo como o Tiny escreve na mensagem de erro => coluna da correção.
  FIELDS = {
    'Bairro' => :bairro, 'Endereço' => :endereco, 'Número' => :numero, 'Complemento' => :complemento,
    'Cidade' => :cidade, 'UF' => :uf, 'CEP' => :cep
  }.freeze

  validates :tiny_order_id, presence: true, uniqueness: true

  scope :awaiting_tiny_fix, -> { where.not(awaiting_tiny_fix_at: nil) }

  def self.for(tiny_order_id)
    find_by(tiny_order_id: tiny_order_id.to_s)
  end

  def awaiting_tiny_fix?
    awaiting_tiny_fix_at.present?
  end

  def hold!(message)
    update!(awaiting_tiny_fix_at: Time.current, awaiting_tiny_fix_message: message.to_s.first(500))
  end

  def release!
    update!(awaiting_tiny_fix_at: nil, awaiting_tiny_fix_message: nil, tiny_fixed_at: Time.current)
  end

  # Valor corrigido do campo (pelo nome que o Tiny usa na mensagem); nil se não houver valor.
  def value_for(field_name)
    column = FIELDS[field_name]
    column && self[column].presence
  end

  # Campo de endereço que o Tiny recusou (extraído da mensagem de erro guardada), ex.: "Bairro".
  def failing_field
    matched = awaiting_tiny_fix_message.to_s[/O campo "(#{FIELDS.keys.join('|')})"/i, 1]
    FIELDS.keys.find { |name| name.casecmp?(matched.to_s) }
  end

  # O que digitar na nota no Tiny.
  def fix_instructions
    field = failing_field
    value = field && value_for(field)
    value ? "Corrija na nota do Tiny: #{field} \"#{value}\"." : "Corrija o endereço da nota no Tiny: #{summary}."
  end

  def summary
    street = [endereco.presence, numero.presence].compact.join(', ')
    place = [cidade.presence, uf.presence].compact.join('/')
    [street.presence, bairro.presence, place.presence, (cep.present? ? "CEP #{cep}" : nil)].compact.join(' - ')
  end
end
