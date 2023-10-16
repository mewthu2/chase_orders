class Tiny::Invoices
  def self.get_invoices(numero_ecommerce)
    # DOC = https://tiny.com.br/api-docs/api2-notas-fiscais-pesquisar
    response = JSON.parse(HTTParty.get(ENV.fetch('NOTAS_FISCAIS_PESQUISA'),
                                       query: { token: ENV.fetch('TOKEN_LOG_PRODUCTION'),
                                                formato: 'json',
                                                numeroEcommerce: numero_ecommerce }))
    response.with_indifferent_access[:retorno][:pedidos]
  end
end