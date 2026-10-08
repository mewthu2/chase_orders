# Sugere Modelo e Cor a partir do nome do produto no Shopify (cada produto é uma cor e a cor é o fim
# do nome: "Legging Apex Seamless Ash"). Produtos que dividem o começo do nome com outro do catálogo
# formam o modelo; sem par, a última palavra vira a cor. Na tela os dois campos são editáveis.
module B2bCatalogs
  module NameSplitter
    module_function

    MIN_STYLE_WORDS = 2

    def split(names)
      words = names.uniq.index_with { |name| name.to_s.split }

      words.to_h do |name, parts|
        shared = words.except(name).values.map { |other| common_prefix(parts, other) }.max.to_i
        shared = [shared, parts.size - 1].min
        shared = parts.size - 1 if shared < MIN_STYLE_WORDS
        shared = parts.size if parts.size == 1

        [name, [parts.first(shared).join(' '), parts.drop(shared).join(' ')]]
      end
    end

    def common_prefix(a, b)
      a.zip(b).take_while { |x, y| x == y }.size
    end
  end
end
