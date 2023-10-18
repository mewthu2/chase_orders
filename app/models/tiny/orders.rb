class Tiny::Orders
  def self.get_orders(situacao_ocorrencia, page)
    # Descrição	          Código
    # Em aberto	          aberto
    # Aprovado	          aprovado
    # Preparando envio	  preparando_envio
    # Faturado (atendido)	faturado
    # Pronto para envio	  pronto_envio
    # Enviado	            enviado
    # Entregue	          entregue
    # Não Entregue	      nao_entregue
    # Cancelado	          cancelado
    response = JSON.parse(HTTParty.get(ENV.fetch('PEDIDOS_PESQUISA'),
                                       query: { token: ENV.fetch('TOKEN_LOG_PRODUCTION'),
                                                formato: 'json',
                                                situacaoOcorrencia: situacao_ocorrencia,
                                                dataInicialOcorrencia: (Date.today - 7.days).strftime('%d/%m/%Y'),
                                                dataFinalOcorrencia: Date.today.strftime('%d/%m/%Y'),
                                                pagina: page }))
    response.with_indifferent_access[:retorno]
  end

  def self.get_all_orders(situacao_ocorrencia)
    response = JSON.parse(HTTParty.get(ENV.fetch('PEDIDOS_PESQUISA'),
                                       query: { token: ENV.fetch('TOKEN_LOG_PRODUCTION'),
                                                formato: 'json',
                                                situacaoOcorrencia: situacao_ocorrencia,
                                                dataInicialOcorrencia: (Date.today - 7.days).strftime('%d/%m/%Y'),
                                                dataFinalOcorrencia: Date.today.strftime('%d/%m/%Y')
                                              }))
    response.with_indifferent_access[:retorno]
  end

  def self.obtain_order(order_id)
    response = JSON.parse(HTTParty.get(ENV.fetch('OBTER_PEDIDO'),
                                       query: { token: ENV.fetch('TOKEN_LOG_PRODUCTION'),
                                                formato: 'json',
                                                id: order_id }))
    response.with_indifferent_access[:retorno]
  end
end