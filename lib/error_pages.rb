# Conteúdo das páginas de erro do Honey (ver lib/tasks/error_pages.rake). Cada página diz o que
# aconteceu, por que costuma acontecer e o que fazer — nada de "We're sorry, but something went wrong".
module ErrorPages
  SUPPORT_URL = 'https://wa.me/5516992375432'.freeze

  PAGES = {
    400 => {
      emoji: '🤔', color: '#f0883e', glow: 'rgba(240,136,62,.38)',
      tab: 'Pedido inválido',
      title: 'Não entendemos esse pedido',
      lead: 'O navegador mandou para o Honey algo que ele não conseguiu ler.',
      reasons: ['Um link copiado pela metade ou alterado à mão.', 'Um formulário enviado com dados corrompidos.', 'Cookies antigos do navegador atrapalhando.'],
      action: 'Volte para a página anterior e tente de novo. Se insistir, limpe os cookies do honey.chasebrasil.com.'
    },
    404 => {
      emoji: '🧭', color: '#3aa3ea', glow: 'rgba(58,163,234,.42)',
      tab: 'Página não encontrada',
      title: 'Essa página não existe',
      lead: 'Procuramos em todos os cantos do Honey e não achamos o endereço que você abriu.',
      reasons: ['O endereço foi digitado ou copiado errado.', 'O item (pedido, chamado, nota…) foi apagado.', 'O link é antigo e a tela mudou de lugar.'],
      action: 'Volte para o início e use o menu ou a busca rápida para chegar onde precisa.'
    },
    422 => {
      emoji: '⏳', color: '#e3b341', glow: 'rgba(227,179,65,.38)',
      tab: 'Ação não concluída',
      title: 'Não deu para concluir essa ação',
      lead: 'O Honey recusou o envio por segurança, e nada foi salvo.',
      reasons: ['A página ficou aberta muito tempo e a sessão expirou.', 'O formulário foi enviado duas vezes.', 'Você saiu da conta em outra aba.'],
      action: 'Recarregue a página (ou entre de novo) e repita a ação.'
    },
    500 => {
      emoji: '🛠️', color: '#f85149', glow: 'rgba(248,81,73,.38)',
      tab: 'Erro no Honey',
      title: 'Algo quebrou do nosso lado',
      lead: 'Um erro inesperado aconteceu no Honey. A culpa não é sua, e o erro ficou registrado para a equipe.',
      reasons: ['Uma falha momentânea no servidor ou no banco de dados.', 'Um serviço externo (Shopify, Correios, SEFAZ…) não respondeu.', 'Um defeito no sistema que precisamos corrigir.'],
      action: 'Espere alguns instantes e tente de novo. Se continuar, fale com o suporte contando o que você estava fazendo.'
    },
    503 => {
      emoji: '🔧', color: '#a371f7', glow: 'rgba(163,113,247,.4)',
      tab: 'Em manutenção',
      title: 'O Honey está em manutenção',
      lead: 'Estamos atualizando o sistema e ele volta em alguns minutos.',
      reasons: ['Uma atualização do Honey está sendo instalada.', 'Uma manutenção programada no servidor.'],
      action: 'Aguarde um pouco e recarregue a página. Nenhum dado seu foi perdido.'
    }
  }.freeze
end
