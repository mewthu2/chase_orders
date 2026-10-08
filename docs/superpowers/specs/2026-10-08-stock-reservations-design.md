# Reserva de Estoque (fila do Tiny) — Design

Data: 2026-10-08

## Objetivo

Itens de pedidos que estão na fila do Tiny (situação `preparando_envio`, ainda não criados no
Correios Log) ficam **reservados**. Todo lugar do Honey que cria pedido usando o estoque do
Correios Log direto passa a enxergar `disponível = estoque Correios − reservado` e bloqueia o que
não couber. Duas telas (B2B e B2C) mostram as reservas.

Exemplo: legging A tem 3 no Correios e 4 em pedidos na fila → um pedido atacado com a legging A
não pode ser salvo, e a tela mostra a reserva como motivo.

## Definições

- **Fila / reserva**: pedido do Tiny em `preparando_envio` **sem** `Attempt` de sucesso de criação
  no Correios (`create_correios_order` para Tiny3/B2C, `create_correios_order_tiny2` para
  Tiny2/B2B). Mesmo critério das telas `order_correios_create` e `order_correios_create_queue_b2b`.
  - B2B (Tiny2): conta **todos** os pedidos em `preparando_envio`, inclusive os que ainda esperam
    aprovação (`Tiny2OrderReview`). Eles já estão na fila e vão consumir o estoque quando aprovados.
- **Fim da reserva**: o pedido ganhou `Attempt` de sucesso (o Correios já desconta do próprio
  estoque) ou saiu de `preparando_envio` (cancelado etc.).
- **Pedidos B2B do Honey** não são somados à parte: ao salvar, eles vão para o Tiny e entram na fila
  por lá. Pedidos que nascem no Tiny continuam sendo barrados pelo próprio Correios.
- **B2C não desconta nada** no sync Correios → Shopify (o Shopify já trata as próprias vendas).
  A tela B2C é informativa.

## Dados

Tabela `stock_reservations`:

| coluna | tipo | obs |
|---|---|---|
| `account` | enum `b2b` / `b2c` | Tiny2 / Tiny3 |
| `tiny_order_id` | string | índice |
| `tiny_order_number` | string | para exibir |
| `customer_name` | string | para exibir |
| `order_date` | date | para exibir |
| `sku` | string | upcase, índice `(account, sku)` |
| `quantity` | decimal | |
| timestamps | | |

Uma linha por (pedido, SKU). Estado do refresh na tabela `stock_reservation_refreshes`, com uma
linha por conta: `account`, `last_refreshed_at`, `status`, `error`. A próxima atualização é
`last_refreshed_at + 10 min`.

## Refresh (`StockReservationRefreshJob`)

Para cada conta:
1. Busca a fila no Tiny (`Tiny::Orders.get_orders_response(..., 'preparando_envio', token, ...)`,
   todas as páginas, mesma janela das telas da fila).
2. Remove os pedidos com `Attempt` de sucesso.
3. Apaga as reservas de pedidos que não estão mais na fila.
4. Para pedidos **novos** (sem linhas na tabela), chama `Tiny::Orders.obtain_order` e grava os
   itens. Pedidos já gravados não são consultados de novo (os itens não mudam enquanto o pedido
   está na fila).
5. Grava `last_refreshed_at`. Erro em um pedido é logado e não para o resto. Erro na listagem
   mantém a foto anterior e marca o refresh com erro.

Agendamento: rake `stock_reservations:refresh` no **Heroku Scheduler a cada 10 min** (mesmo padrão
de `tickets:notify_overdue`). Botão "Atualizar agora" nas telas roda o job na hora.

`StockReservation.reserved_for(sku, account:)` → soma das quantidades.

Duas execuções ao mesmo tempo (scheduler + botão) não podem duplicar linhas: se a conta já está
`running` há menos de 5 min, a nova execução é ignorada.

## Bloqueio no Pedido B2B (venda/atacado, abastecimento, transferência B2C)

Todos usam o estoque B2B do Correios (`from_tiny2: true`), então descontam a reserva **B2B**.

- `product_stock` (`B2bOrdersController#correios_stock_for`) passa a devolver `stock`, `reserved`,
  `quantity` (= disponível) e o status calculado sobre o disponível.
- Na linha do item, a tela mostra **Estoque / Reservado / Disponível**, com link do reservado para
  a tela de reservas filtrada pelo SKU.
- **Bloqueio já ao adicionar** (enquanto o pedido não foi para o Tiny). Exemplo: estoque 3, 3 na
  fila do Tiny → disponível 0 → não dá para adicionar nem 1 legging A.
  - Seletor de produtos: variante com disponível ≤ 0 fica desabilitada, com "0 disponível · N
    reservados na fila". "Selecionar todas" só marca as habilitadas.
  - Planilha: as linhas importadas têm o estoque consultado na hora; SKU sem disponível é removido
    e quantidade acima do disponível é reduzida ao disponível, com aviso listando o que mudou.
  - Quantidade: o campo fica limitado ao disponível (digitar acima volta para o máximo, com aviso).
  - Itens que já estavam no pedido ao abrir a edição não são alterados sozinhos: ficam em vermelho
    com "faltam N · X reservados na fila" e o servidor barra o salvamento até o usuário ajustar.
  - Se o Correios não responder para um SKU, ele não é bloqueado (nem na tela nem no servidor).
- Acima dos itens: "Reservas atualizadas há N min · próxima às HH:MM".
- **Validação no servidor** (create/update/transmit): se algum item passar do disponível, o
  pedido não é salvo/enviado e o erro lista os SKUs (mesmo SKU em duas linhas é somado). A
  validação só vale enquanto o pedido **não chegou ao Tiny** (`tiny_reference_id` vazio) e não está
  cancelado: depois de enviado, os itens dele já fazem parte da reserva e mudar status não pode
  ser barrado pelo próprio pedido.
- Se o Correios não responder, o comportamento atual é mantido (status `error`, sem bloqueio pela
  reserva).

## Telas de Reserva (B2B e B2C)

Rotas `stock_reservations/b2b` e `stock_reservations/b2c`, cada uma com a própria permissão de
tela (`guard_screen`) e item no sidebar ao lado das filas do Correios.

- Cabeçalho: última atualização, próxima atualização, botão "Atualizar agora".
- KPIs: pedidos na fila, SKUs reservados, unidades reservadas.
- Tabela por SKU: SKU, produto, reservado, nº de pedidos; expande para os pedidos (número Tiny,
  cliente, data, quantidade).
- Busca por SKU (aceita `?sku=` vindo do pedido B2B).
- Visual no padrão das telas atuais, com transições e destaques animados.

## Fora do escopo

- POS/PDV, planner orders, retiradas e transferências internas (usam Shopify ou outro estoque).
- Desconto da reserva B2C no sync com o Shopify.
- Somar pedidos B2B do Honey ainda não enviados ao Tiny.

## Testes

- Model: `reserved_for` soma por conta e ignora maiúsculas/minúsculas no SKU.
- Job: entra pedido novo, sai pedido com Attempt de sucesso, sai pedido fora da fila, pedido já
  gravado não chama `obtain_order` de novo, falha na listagem preserva a foto (Tiny mockado).
- Controller: `product_stock` devolve reservado/disponível; create/update bloqueiam acima do
  disponível.
