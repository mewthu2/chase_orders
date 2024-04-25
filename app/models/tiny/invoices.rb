class Tiny::Invoices
  class << self
    def get_invoices(numero_ecommerce)
      # DOC = https://tiny.com.br/api-docs/api2-notas-fiscais-pesquisar
      response = JSON.parse(HTTParty.get(ENV.fetch('NOTAS_FISCAIS_PESQUISA'),
                                         query: { token: ENV.fetch('TOKEN_TINY_PRODUCTION'),
                                                  formato: 'json',
                                                  numeroEcommerce: numero_ecommerce }))
      response.with_indifferent_access[:retorno][:pedidos]
    end

    def obtain_invoice(invoice_id)
      response = JSON.parse(HTTParty.get(ENV.fetch('OBTER_NOTA_FISCAL'),
                                         query: { token: ENV.fetch('TOKEN_TINY_PRODUCTION'),
                                                  formato: 'json',
                                                  id: invoice_id }))
      response.with_indifferent_access[:retorno][:nota_fiscal]
    end

    def obtain_xml(invoice_id)
      HTTParty.get(ENV.fetch('OBTER_XML_NOTA_FISCAL'),
                   query: { token: ENV.fetch('TOKEN_TINY_PRODUCTION'),
                            formato: 'string',
                            id: invoice_id })
    end

    def invoice_emition(invoice_id)
      HTTParty.get(ENV.fetch('EMITIR_NOTA_FISCAL'),
                   query: { token: ENV.fetch('TOKEN_TINY_PRODUCTION'),
                            formato: 'string',
                            id: invoice_id })
    end
  end
end
