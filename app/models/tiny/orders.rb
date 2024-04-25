class Tiny::Orders
  class << self
    def get_orders(situacao, page)
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
                                         query: { token: ENV.fetch('TOKEN_TINY_PRODUCTION'),
                                                  formato: 'json',
                                                  situacao:,
                                                  dataInicialOcorrencia: (Date.today - 7.days).strftime('%d/%m/%Y'),
                                                  dataFinalOcorrencia: Date.today.strftime('%d/%m/%Y'),
                                                  pagina: page }))
      response.with_indifferent_access[:retorno]
    end

    def get_all_orders(situacao)
      response = JSON.parse(HTTParty.get(ENV.fetch('PEDIDOS_PESQUISA'),
                                         query: { token: ENV.fetch('TOKEN_TINY_PRODUCTION'),
                                                  formato: 'json',
                                                  situacao: }))
      total = []
      if response.with_indifferent_access[:retorno][:numero_paginas].present?
        response.with_indifferent_access[:retorno][:numero_paginas].times do |re|
          total << JSON.parse(HTTParty.get(ENV.fetch('PEDIDOS_PESQUISA'),
                                           query: { token: ENV.fetch('TOKEN_TINY_PRODUCTION'),
                                                    formato: 'json',
                                                    situacao:,
                                                    pagina: re }))
        end
        total.first.with_indifferent_access[:retorno]
      else
        response = JSON.parse(HTTParty.get(ENV.fetch('PEDIDOS_PESQUISA'),
                                           query: { token: ENV.fetch('TOKEN_TINY_PRODUCTION'),
                                                    formato: 'json',
                                                    situacao: }))
        response.with_indifferent_access[:retorno]
      end
    end

    def obtain_order(order_id)
      response = JSON.parse(HTTParty.get(ENV.fetch('OBTER_PEDIDO'),
                                         query: { token: ENV.fetch('TOKEN_TINY_PRODUCTION'),
                                                  formato: 'json',
                                                  id: order_id }))
      response.with_indifferent_access[:retorno]
    end

    def send_tracking(order_id, tracking)
      response = JSON.parse(HTTParty.get(ENV.fetch('TINY_SEND_TRACKING'),
                                         query: { token: ENV.fetch('TOKEN_TINY_PRODUCTION'),
                                                  formato: 'json',
                                                  id: order_id,
                                                  codigoRastreamento: tracking }))
      response.with_indifferent_access[:retorno]
    end

    def change_situation(order_id, new_situation)
      response = JSON.parse(HTTParty.get(ENV.fetch('ALTERAR_SITUACAO_PEDIDO'),
                                         query: { token: ENV.fetch('TOKEN_TINY_PRODUCTION'),
                                                  formato: 'string',
                                                  id: order_id,
                                                  situacao: new_situation }))
      response.with_indifferent_access[:retorno]
    end
  end
end
