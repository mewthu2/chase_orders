module Whatsapp
  # O agente de IA de uma automação. Lê os comandos ensinados e a conversa, e decide:
  #   reply  → responder ao cliente
  #   finish → responder (opcional) e finalizar a conversa
  #   unsure → "não sei o que fazer neste caso": fica pendente para a equipe ensinar
  #   wait   → nada a responder agora (ex.: o cliente só mandou "ok")
  # A chave da OpenAI fica só na variável OPENAI_API_KEY do servidor.
  class Agent
    class NotConfigured < StandardError; end
    class Failure < StandardError; end
    Decision = Struct.new(:action, :reply, :question, :reason, keyword_init: true) do
      def reply? = %w[reply finish].include?(action) && reply.present?
      def finish? = action == 'finish'
      def unsure? = action == 'unsure'
    end
    ACTIONS = %w[reply finish unsure wait].freeze
    ENDPOINT = 'https://api.openai.com/v1/chat/completions'.freeze
    HISTORY = 30

    def self.configured? = ENV['OPENAI_API_KEY'].present?
    def self.model = ENV['OPENAI_MODEL'].presence || 'gpt-4.1-mini'

    def initialize(automation)
      @automation = automation
    end

    # history: [{ from: 'cliente'|'loja', text:, at: }] em ordem cronológica.
    def decide(history, contact_name: nil)
      raise NotConfigured, 'A chave da OpenAI (OPENAI_API_KEY) não está configurada no servidor.' unless self.class.configured?
      body = { model: self.class.model, response_format: { type: 'json_object' },
               messages: [{ role: 'system', content: system_prompt(contact_name) },
                          { role: 'user', content: transcript(history) }] }
      parse(request(body))
    end

    def system_prompt(contact_name = nil)
      rules = @automation.rules.select(&:active?)
      commands = if rules.any?
        rules.each_with_index.map { |r, i| "#{i + 1}. QUANDO: #{r.trigger.squish}\n   FAÇA: #{r.response.strip}" }.join("\n")
      else
        '(nenhum comando ensinado ainda)'
      end
      <<~PROMPT
        Você é o agente de atendimento pelo WhatsApp da CHASE (moda fitness e lifestyle), atendendo pelo número "#{@automation.connection.name}".
        Hoje é #{Date.current.strftime('%d/%m/%Y')} (#{%w[domingo segunda-feira terça-feira quarta-feira quinta-feira sexta-feira sábado][Date.current.wday]}), #{Time.current.strftime('%H:%M')} no horário de Brasília.
        #{"O nome do cliente no WhatsApp é \"#{contact_name}\"." if contact_name.present?}

        INSTRUÇÕES GERAIS DA EQUIPE:
        #{@automation.instructions.presence || '(nenhuma)'}

        COMANDOS ENSINADOS PELA EQUIPE (siga-os à risca):
        #{commands}

        REGRAS QUE VOCÊ NUNCA QUEBRA:
        - Responda só com base nos comandos e instruções acima e no que o próprio cliente disse na conversa.
        - Nunca invente prazos, valores, situação de pedido, estoque, estorno, links ou telefones que não estejam nos comandos.
        - Nunca responda "sim", "não", "temos" ou "não temos" sobre algo que os comandos não dizem (ex.: desconto, cupom, promoção, Black Friday, preço, tamanho ou cor disponível, frete). Nesses casos use "unsure".
        - Se a última mensagem do cliente pede algo que os comandos não cobrem, ou se você não tem certeza de como a equipe responderia, use a ação "unsure". É melhor deixar para a equipe do que errar.
        - Cliente irritado, reclamação séria, ameaça de expor a marca, pedido de estorno ou cobrança indevida sem comando específico: "unsure".
        - Use "finish" só quando um comando mandar finalizar ou quando o cliente deixar claro que está tudo resolvido (ex.: agradeceu e se despediu). Em "finish", a resposta pode ser uma despedida curta ou vazia.
        - A última mensagem é da cliente: SEMPRE escreva uma sugestão de resposta em "reply", analisando o contexto da conversa inteira (inclusive em "unsure").
        - Em "unsure", a sugestão deve ser segura e não inventar nada: por exemplo, pedir o dado que falta (número do pedido, e-mail da compra) ou dizer que vai verificar com a equipe e já retorna. A equipe decide se envia.
        - Use "wait" só se a mensagem da cliente claramente não pede resposta (ex.: um "ok" ou emoji solto no meio do atendimento).
        - Escreva em português do Brasil, no tom de WhatsApp: cordial, curto, sem formalidade excessiva, chamando pelo nome quando souber. Pode usar *negrito* do WhatsApp com moderação.
        - Não diga que é uma IA a menos que perguntem diretamente.

        Responda APENAS com um JSON neste formato:
        {"action": "reply" | "finish" | "unsure" | "wait",
         "reply": "texto sugerido para enviar à cliente (sempre preenchido, exceto em wait)",
         "question": "em unsure: resuma em uma frase o que o cliente quer e que a equipe precisa ensinar",
         "reason": "uma frase curta explicando qual comando você usou ou por que não soube"}
      PROMPT
    end

    private

    def transcript(history)
      lines = history.last(HISTORY).map do |m|
        who = m[:from] == 'cliente' ? 'CLIENTE' : 'LOJA'
        "[#{m[:at]&.in_time_zone&.strftime('%d/%m %H:%M')}] #{who}: #{m[:text].to_s.truncate(1_500)}"
      end
      "Conversa até agora (a mais recente por último):\n#{lines.join("\n")}\n\nDecida a próxima ação para a última mensagem do CLIENTE."
    end

    def request(body)
      response = Faraday.new(request: { timeout: 60, open_timeout: 10 }).post(ENDPOINT) do |req|
        req.headers['Authorization'] = "Bearer #{ENV.fetch('OPENAI_API_KEY')}"
        req.headers['Content-Type'] = 'application/json'
        req.body = body.to_json
      end
      unless response.success?
        detail = (JSON.parse(response.body).dig('error', 'message') rescue nil)
        raise Failure, "OpenAI respondeu #{response.status}#{": #{detail.to_s.truncate(160)}" if detail}"
      end
      JSON.parse(response.body).dig('choices', 0, 'message', 'content').to_s
    rescue Faraday::Error => e
      raise Failure, "Sem comunicação com a OpenAI (#{e.class.name.demodulize})."
    end

    def parse(content)
      data = JSON.parse(content)
      action = ACTIONS.include?(data['action']) ? data['action'] : 'unsure'
      decision = Decision.new(action: action, reply: data['reply'].to_s.strip.truncate(4_000),
                              question: data['question'].to_s.strip.truncate(1_000), reason: data['reason'].to_s.strip.truncate(300))
      decision.action = 'unsure' if decision.action == 'reply' && decision.reply.blank?
      decision.action = 'reply' if decision.action == 'wait' && decision.reply.present?
      decision.question = 'O cliente fez uma pergunta que os comandos ainda não cobrem.' if decision.unsure? && decision.question.blank?
      decision
    rescue JSON::ParserError
      Decision.new(action: 'unsure', question: 'O agente não conseguiu entender a conversa.', reason: 'Resposta inválida da OpenAI.')
    end
  end
end
