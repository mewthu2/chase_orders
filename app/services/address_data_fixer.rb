require 'erb'

# Completa dados de endereço que vieram faltando do Tiny (bairro e número), consultando APIs públicas
# de CEP. O resultado vira uma AddressCorrection do pedido, que a criação no Correios já usa no lugar
# do endereço do Tiny.
#
# Bairro, em ordem:
#   1. CEP no ViaCEP (e na BrasilAPI se o ViaCEP falhar);
#   2. rua na busca por endereço do ViaCEP (UF/cidade/logradouro), quando todos os resultados têm o mesmo bairro;
#   3. bairro escrito no complemento (ex.: "Abaixo da prefeitura, Centro");
#   4. bairro mais comum da busca pela rua;
#   5. "Centro" quando o CEP é o geral da cidade (termina em 000), único caso em que não há bairro no CEP.
# Número: o que estiver no fim da rua ("Rua A, 123" ou "Rua A nº 123") ou no começo do complemento; senão "S/N".
class AddressDataFixer
  VIACEP = 'https://viacep.com.br/ws'.freeze
  BRASILAPI = 'https://brasilapi.com.br/api/cep/v2'.freeze
  TIMEOUT = 8
  STREET_TYPES = /\A(rua|r\.|avenida|av\.?|travessa|tv\.?|alameda|al\.?|rodovia|rod\.?|estrada|est\.?|praça|pça\.?|largo|via|beco|quadra|qd\.?)\s+/i
  BAIRRO_HINT = /\A(centro|bairro\s+.+|setor\s+.+|jardim\s+.+|jd\.?\s+.+|vila\s+.+|vl\.?\s+.+|parque\s+.+|pq\.?\s+.+|conjunto\s+.+|residencial\s+.+|loteamento\s+.+|distrito\s+.+|zona\s+(rural|urbana))\z/i
  GENERIC_BAIRRO = 'Centro'.freeze
  NO_NUMBER = 'S/N'.freeze

  Result = Struct.new(:changes, :sources, keyword_init: true) do
    def any? = changes.any?
  end

  # address: hash com :endereco, :numero, :complemento, :bairro, :cep, :cidade, :uf (como vem do Tiny).
  def initialize(address)
    @address = address.to_h.transform_keys(&:to_sym).transform_values { |v| v.to_s.strip }
  end

  def call
    changes = {}
    sources = []

    if @address[:bairro].blank?
      bairro, source = find_bairro
      if bairro.present?
        changes[:bairro] = bairro.first(60)
        sources << "bairro via #{source}"
      end
    end

    if @address[:numero].blank?
      numero, endereco, source = find_numero
      changes[:numero] = numero
      changes[:endereco] = endereco if endereco.present? && endereco != @address[:endereco]
      sources << "número via #{source}"
    end

    Result.new(changes: changes, sources: sources)
  end

  # Salva (ou completa) a correção do pedido; não sobrescreve o que alguém já corrigiu à mão.
  def self.apply!(tiny_order_id, address)
    result = new(address).call
    return nil unless result.any?

    correction = AddressCorrection.find_or_initialize_by(tiny_order_id: tiny_order_id.to_s)
    result.changes.each { |field, value| correction[field] = value if correction[field].blank? }
    return nil unless correction.changed?

    correction.save!
    Rails.logger.info("[AddressDataFixer] pedido #{tiny_order_id}: #{result.changes.inspect} (#{result.sources.join('; ')})")
    correction
  end

  private

  def cep = @address[:cep].gsub(/\D/, '')

  def find_bairro
    from_cep = cep_lookup
    return [from_cep, 'CEP'] if from_cep.present?

    street_bairros = street_lookup
    return [street_bairros.first, 'busca pela rua'] if street_bairros.uniq.size == 1

    hint = complement_bairro
    return [hint, 'complemento'] if hint.present?

    if street_bairros.any?
      return [street_bairros.tally.max_by { |_, count| count }.first, 'busca pela rua (mais comum)']
    end

    return [GENERIC_BAIRRO, 'CEP geral da cidade'] if cep.end_with?('000')

    nil
  end

  def cep_lookup
    return nil unless cep.size == 8

    body = get_json("#{VIACEP}/#{cep}/json/")
    return body['bairro'].to_s.strip.presence if body.is_a?(Hash) && !body['erro']

    body = get_json("#{BRASILAPI}/#{cep}")
    body.is_a?(Hash) ? body['neighborhood'].to_s.strip.presence : nil
  end

  # Bairros dos CEPs da rua na cidade (sem os de agência dos Correios quando houver outros).
  def street_lookup
    street = @address[:endereco].sub(/\s*,.*\z/, '').sub(STREET_TYPES, '').strip
    uf = @address[:uf].upcase
    city = @address[:cidade]
    return [] if street.size < 3 || uf.size != 2 || city.size < 3

    url = "#{VIACEP}/#{ERB::Util.url_encode(uf)}/#{ERB::Util.url_encode(city)}/#{ERB::Util.url_encode(street)}/json/"
    rows = Array(get_json(url)).select { |r| r.is_a?(Hash) && r['bairro'].present? }
    regular = rows.select { |r| r['unidade'].blank? }
    (regular.presence || rows).map { |r| r['bairro'].strip }
  end

  def complement_bairro
    @address[:complemento].split(/[,;\-–]/).map(&:strip).reverse.find { |part| part.match?(BAIRRO_HINT) }
  end

  def find_numero
    if (m = @address[:endereco].match(/\A(.+?)\s*(?:,\s*(?:n[º°o.]?\s*)?|\s+n[º°o.]\s*)(\d{1,6})\s*\z/i))
      return [m[2], m[1].strip, 'rua']
    end
    if (m = @address[:complemento].match(/\A(?:n[º°o.]?\s*)?(\d{1,6})\b/i))
      return [m[1], nil, 'complemento']
    end

    [NO_NUMBER, nil, 'sem número']
  end

  def get_json(url)
    response = HTTParty.get(url, timeout: TIMEOUT, headers: { 'Accept' => 'application/json' })
    response.success? ? JSON.parse(response.body) : nil
  rescue StandardError => e
    Rails.logger.warn("[AddressDataFixer] #{url}: #{e.message}")
    nil
  end
end
