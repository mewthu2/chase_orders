module Whatsapp
  # Funcionalidade do agente numa automação: uma classe de pergunta ("quando a cliente perguntar…") ligada a uma
  # consulta de verdade, que o agente faz antes de responder. Nasce desligada; no "Testar o agente" vale mesmo assim.
  class AutomationCapability < ApplicationRecord
    CATALOG = {
      'stock_lookup' => {
        name: 'Disponibilidade nas lojas', icon: 'fas fa-store',
        trigger: 'a cliente perguntar se um produto, cor ou tamanho está disponível, ou em qual loja tem',
        does: 'Consulta o estoque na Shopify e responde em quais lojas tem o produto (e em quais tamanhos).',
        tool: 'consultar_estoque',
        guide: 'Chame consultar_estoque com o produto como a cliente descreveu (modelo, linha e cor) e o tamanho, se ela disse. ' \
               'Se ela não disse qual produto, pergunte antes. Responda dizendo em quais lojas tem, sem citar quantidades. ' \
               'Se a ferramenta trouxer vários produtos parecidos, pergunte qual deles ela quer.'
      },
      'order_lookup' => {
        name: 'Pedido da cliente', icon: 'fas fa-box',
        trigger: 'a cliente perguntar sobre um pedido (situação, pagamento, entrega ou rastreio)',
        does: 'Pede o e-mail usado na compra e procura o pedido na Shopify (situação, itens e rastreio).',
        tool: 'buscar_pedidos',
        guide: 'Se a cliente ainda não escreveu o e-mail da compra na conversa, NÃO chame a ferramenta: peça o e-mail na resposta. ' \
               'Com o e-mail escrito por ela, chame buscar_pedidos (com o número do pedido, se ela disse). ' \
               'Conte a situação com as palavras da ferramenta e mande o rastreio quando houver. ' \
               'Se não achar pedido com esse e-mail, peça para ela conferir o e-mail ou mandar o número do pedido.'
      }
    }.freeze

    belongs_to :automation, inverse_of: :capabilities
    validates :key, inclusion: { in: CATALOG.keys }, uniqueness: { scope: :automation_id }
    validates :trigger, length: { maximum: 1_000 }

    def info = CATALOG.fetch(key)
    def name = info[:name]
    def trigger_text = trigger.presence || info[:trigger]
  end
end
