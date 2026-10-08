# CNPJ do lojista que se identifica no catálogo geral.
module B2bCatalogs
  module Cnpj
    module_function

    WEIGHTS_1 = [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2].freeze
    WEIGHTS_2 = [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2].freeze

    def digits(value) = value.to_s.gsub(/\D/, '')

    def valid?(value)
      numbers = digits(value)
      return false unless numbers.length == 14 && numbers.chars.uniq.size > 1

      base = numbers[0, 12].chars.map(&:to_i)
      first = check_digit(base, WEIGHTS_1)
      second = check_digit(base + [first], WEIGHTS_2)
      numbers[12, 2] == "#{first}#{second}"
    end

    def format(value)
      numbers = digits(value)
      return value.to_s unless numbers.length == 14

      numbers.sub(/(\d{2})(\d{3})(\d{3})(\d{4})(\d{2})/, '\1.\2.\3/\4-\5')
    end

    def check_digit(numbers, weights)
      rest = numbers.zip(weights).sum { |n, w| n * w } % 11
      rest < 2 ? 0 : 11 - rest
    end
  end
end
