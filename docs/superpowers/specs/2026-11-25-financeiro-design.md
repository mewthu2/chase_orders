# Financeiro — Etapa 1 (pedidos de atacado, consultores e comissões) + tela inicial sem chamados

## Por quê

O financeiro precisa acompanhar o recebimento dos pedidos de atacado e pagar comissão a quem
digita o pedido e ao consultor que vendeu. Hoje o pedido só tem um texto livre "Vendedor"
(`b2b_orders.salesperson_name`) e a forma de pagamento é só registro (`payment_method`,
`payment_terms` "30 60 90", `B2bOrder#installments`). Não há onde dar baixa em boleto nem
calcular comissão.

## Objetivos

1. Nova área **Financeiro** no menu, visível só para o usuário financeiro@chasebrasil.com e admins.
2. **Pedidos (conferência de recebimento):** lista dos pedidos de atacado (kind `sale`) com
   forma de pagamento, parcelas, vencimentos e situação. PIX e cartão aparecem pagos; boleto
   fica pendente até o financeiro dar baixa **em cada parcela**.
3. **Consultores:** cadastro (nome, e opcionalmente CPF, telefone, e-mail, PIX, ativo). No pedido
   de atacado o usuário escolhe o consultor da lista; se não estiver, digita só um primeiro nome e
   o financeiro depois completa o cadastro e vincula.
4. **Percentuais de comissão:** tabela por mês e por pessoa (usuário que digita e consultor).
5. **Comissões:** por mês, quanto cada pessoa tem de comissão, com o detalhe de cada pedido/parcela.
6. **Sem número do Tiny no atacado:** pedidos vindos do Tiny não existem mais; o número/coluna do
   Tiny some das telas do atacado (lista de pedidos, busca, formulário) e das filas do Log02.
7. **Tela inicial do Honey sem chamados:** os chamados somem do menu e da home; a home vira uma
   tela limpa com uma busca central "O que você precisa hoje?" sobre as telas que o usuário pode abrir.

## Não-objetivos (Etapa 1)

- Pagar a comissão / marcar comissão como paga / fechar o mês (pode vir depois como "fechar mês",
  que congela o resultado).
- Travar o fluxo do Log02 por falta de pagamento. O Financeiro não interfere na expedição.
- Gerar boleto, conciliar banco ou integrar com Tiny (regra da casa: nada de Tiny no fluxo).
- Apagar o código dos chamados (só esconder; reversível).

## Anti-objetivos

- Comissão que não bate com os pedidos (por isso o cálculo é feito na hora — abordagem A).
- Mudar valores de comissão de meses passados quando alguém troca o percentual de outro mês.

## Regras de negócio

**Início:** desde sempre — todos os pedidos `sale` não cancelados entram na conferência e na
comissão, com as parcelas dos boletos geradas para o histórico (backfill). Não há pedidos vindos do
Tiny a tratar. Como o histórico traz boletos antigos ainda sem baixa, a tela de pedidos permite
**dar baixa em várias parcelas de uma vez** (seleção + data do pagamento).

**Base da comissão:** o total do pedido **com frete** — `B2bOrder#grand_total` (produtos com
desconto + frete). Só pedidos `sale`, não cancelados.

**Quem digitou** (`b2b_orders.user_id`, usuário do sistema): comissão = `grand_total × % do
digitador no mês`, entra no **mês de criação do pedido**, sem esperar pagamento.

**Consultor:** só entra quando pago, no mês do recebimento, com o % do consultor daquele mês:
- **PIX** e **cartão** (mesmo parcelado): pago na criação do pedido → total entra no mês do pedido.
- **Boleto:** cada parcela entra no mês em que o financeiro deu baixa nela
  (`valor da parcela × %`). Boleto 30/60/90 → 1/3 por boleto pago.
- Pedido sem forma de pagamento: tratado como boleto à vista pendente (uma parcela).

**Percentual:** por mês (ano-mês) e por pessoa. Botão "copiar do mês anterior" (ação explícita;
abrir um mês nunca grava nada, meses passados não mudam sozinhos). Pessoa sem percentual no mês → comissão 0 e aviso "sem percentual".

**Cancelamento:** pedido cancelado some da comissão (inclusive parcelas já baixadas, que ficam
registradas mas não somam).

**Consultor pendente** (só nome digitado, sem cadastro vinculado): a comissão é calculada e
aparece sob esse nome com o aviso "cadastro pendente"; o percentual só pode ser configurado
depois de vincular ao cadastro, então até lá fica sem percentual (0) — o aviso deixa isso claro.

## Abordagem

Consideradas:
- **A) Comissão calculada na hora (escolhida).** A tela monta a conta a partir dos pedidos, das
  parcelas baixadas e do percentual do mês. Cancelamentos, correções e vínculo de consultor
  refletem sozinhos. Desvantagem: editar o valor de um pedido antigo muda a comissão daquele mês.
- **B) Lançamentos de comissão gravados** por evento, com valor congelado. Histórico imutável, mas
  cada cancelamento/edição exige estorno — mais código e risco de divergência. Descartada.

## Dados (novas tabelas/colunas)

> O banco de dev é o de produção: migrações só aditivas, rodadas pelo deploy, testadas no MySQL
> temporário de testes.

- `consultants`: `name` (obrigatório), `document`, `phone`, `email`, `pix_key`, `active` (default true), timestamps.
- `b2b_orders.consultant_id` (FK opcional). O campo texto `salesperson_name` continua guardando o
  nome digitado quando não há cadastro; com `consultant_id`, ele é preenchido com o nome do cadastro.
- `b2b_order_payments` (parcelas): `b2b_order_id`, `number`, `due_date`, `amount`, `paid_at`,
  `paid_by_id` (user), timestamps. Gerada para boletos a partir de `B2bOrder#installments`
  (boleto sem prazo = 1 parcela à vista vencendo na data do pedido). Ao editar o pedido (valor
  ou prazos), as parcelas **ainda não pagas** são refeitas; se já houver parcela paga e os prazos
  mudarem, mantém as pagas e recalcula o restante sobre o saldo. *(decisão do builder, ver abaixo)*
- `commission_rates`: `month` (date, dia 1), `beneficiary_type` (`User`/`Consultant`),
  `beneficiary_id`, `percent` decimal(5,2); índice único (month, beneficiary).

## Acesso

- `Screen::AREAS['financeiro']` (nova área, cor/ícone próprios) com as telas
  `finance_orders` (V, E = dar baixa/estornar), `consultants` (VCED), `commissions` (V, E = editar
  percentuais, P = exportar).
- Um perfil **Financeiro** com essas permissões, atribuído ao usuário financeiro@chasebrasil.com
  (via migração de dados/rake, com `update_columns`/sem e-mails). Admins veem tudo pelo perfil admin.
- No **formulário do pedido de atacado** o campo Vendedor vira "Consultor": select com busca dos
  consultores ativos + opção de digitar um nome livre. Quem cria pedido continua o mesmo perfil de hoje.

## Telas

1. **Financeiro → Pedidos de Atacado:** filtro de mês com setas (igual Notas Fiscais) e período,
   filtros por situação (pago / pendente / vencido) e forma de pagamento. Cada pedido mostra
   número, cliente, consultor (com selo "pendente"), digitador, total com frete, forma e parcelas
   com vencimento e situação; botão para dar baixa em cada parcela (data do pagamento, padrão hoje)
   e para desfazer a baixa. Totais do filtro: recebido, a receber, vencido.
2. **Financeiro → Consultores:** lista + cadastro; seção "nomes pendentes" com os nomes livres
   usados nos pedidos e o botão para criar cadastro ou vincular a um existente (vincula todos os
   pedidos com aquele nome).
3. **Financeiro → Comissões:** mês com setas; tabela por pessoa (digitadores e consultores) com
   percentual do mês (editável ali mesmo), base e comissão; abrir a pessoa mostra os pedidos e
   parcelas que compõem o valor. Exportar CSV.
4. **Home:** busca central sobre `Navigation.for(current_user)` + extras, mesma fonte do Ctrl+K;
   sem atalhos de chamado. Rotas dos chamados continuam funcionando por URL.

Visual: seguir o padrão vivo/animado do Honey (ver memória de design).

**Digitadores listados:** quem digitou pedido no mês; sem percentual aparece em cinza com R$ 0.

## Decisões deixadas ao builder (marcadas como proposta)

- Regras de recálculo de parcelas após edição do pedido com parcela já paga (proposta acima).
- Data base dos vencimentos = data de criação do pedido (já é a de `installments`).
- Mês inicial da comissão: os meses só mostram valores quando houver percentuais cadastrados.
