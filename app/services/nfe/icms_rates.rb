module Nfe
  # Alíquotas de ICMS usadas na venda interestadual a consumidor final (DIFAL).
  # A tabela interna é só o ponto de partida de cada natureza de operação: revisar com o contador e ajustar na tela.
  module IcmsRates
    module_function

    # Alíquota interna modal e FCP de cada UF (em %).
    INTERNAL = {
      'AC' => [19, 0], 'AL' => [19, 1], 'AM' => [20, 0], 'AP' => [18, 0], 'BA' => [20.5, 0], 'CE' => [20, 0],
      'DF' => [20, 0], 'ES' => [17, 0], 'GO' => [19, 0], 'MA' => [23, 0], 'MG' => [18, 0], 'MS' => [17, 0],
      'MT' => [17, 0], 'PA' => [19, 0], 'PB' => [20, 0], 'PE' => [20.5, 0], 'PI' => [22.5, 0], 'PR' => [19.5, 0],
      'RJ' => [20, 2], 'RN' => [20, 0], 'RO' => [19.5, 0], 'RR' => [20, 0], 'RS' => [17, 0], 'SC' => [17, 0],
      'SE' => [19, 1], 'SP' => [18, 0], 'TO' => [20, 0]
    }.freeze

    # Sul e Sudeste (menos ES) vendendo para Norte, Nordeste, Centro-Oeste e ES: 7%. Demais: 12%.
    SOUTH_SOUTHEAST = %w[MG PR RJ RS SC SP].freeze
    # Origem estrangeira (Resolução do Senado 13/2012): 4%.
    IMPORTED_ORIGINS = [1, 2, 3, 8].freeze

    def default_table
      INTERNAL.transform_values { |internal, fcp| { 'internal' => internal.to_s, 'fcp' => fcp.to_s } }
    end

    def interstate(from, to, origin = 0)
      return BigDecimal('4') if IMPORTED_ORIGINS.include?(origin.to_i)
      return BigDecimal('7') if SOUTH_SOUTHEAST.include?(from) && !SOUTH_SOUTHEAST.include?(to)

      BigDecimal('12')
    end
  end
end
