module Nfe
  module Cnpj
    module_function

    def digits(value)
      value.to_s.gsub(/\D/, '')
    end

    def valid?(value)
      d = digits(value)
      return false unless d.length == 14 && d.chars.uniq.length > 1

      base = d[0, 12].chars.map(&:to_i)
      first = check_digit(base, [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2])
      second = check_digit(base + [first], [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2])
      d[12, 2] == "#{first}#{second}"
    end

    def valid_cpf?(value)
      d = digits(value)
      return false unless d.length == 11 && d.chars.uniq.length > 1

      base = d[0, 9].chars.map(&:to_i)
      first = check_digit(base, (2..10).to_a.reverse)
      second = check_digit(base + [first], (2..11).to_a.reverse)
      d[9, 2] == "#{first}#{second}"
    end

    def valid_document?(value)
      digits(value).length == 11 ? valid_cpf?(value) : valid?(value)
    end

    def format(value)
      digits(value).sub(/(\d{2})(\d{3})(\d{3})(\d{4})(\d{2})/, '\1.\2.\3/\4-\5')
    end

    def check_digit(numbers, weights)
      remainder = numbers.zip(weights).sum { |n, w| n * w } % 11
      remainder < 2 ? 0 : 11 - remainder
    end
  end
end
