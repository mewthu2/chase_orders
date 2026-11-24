# Lê campos de Attempt#params quando ele foi gravado como texto de um Hash (o Rails converte o Hash
# com to_s ao salvar na coluna text). O formato desse texto mudou no Ruby 3.4:
#   Ruby <= 3.3: {:nome=>"Ana", :itens=>[{:codigo=>"X", :quantidade=>"2"}]}
#   Ruby >= 3.4: {nome: "Ana", itens: [{codigo: "X", quantidade: "2"}]}
# Os registros antigos continuam no banco, então os dois formatos precisam ser lidos.
module AttemptParamsText
  module_function

  def value(text, key)
    text.to_s.match(/#{key_pattern(key)}"([^"]*)"/)&.captures&.first
  end

  # Quantidade do item com esse código (no array de itens do pedido), ou '0'.
  def item_quantity(text, product_code)
    item = text.to_s.scan(/\{[^{}]*#{key_pattern(:codigo)}"#{Regexp.escape(product_code.to_s)}"[^{}]*\}/).first
    value(item, :quantidade) || '0'
  end

  def key_pattern(key)
    name = Regexp.escape(key.to_s)
    "(?::#{name}=>|(?<![\\w\"])#{name}: )"
  end
end
