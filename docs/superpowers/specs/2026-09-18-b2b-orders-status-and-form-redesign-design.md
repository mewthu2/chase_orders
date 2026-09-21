# Pedidos B2B — status do Tiny, campos do formulário e desconto por item

Data: 2026-09-18

## Contexto

A tela de Pedidos B2B (`B2bOrder`) hoje tem um fluxo de status interno e local
(`draft`, `saved`, `transmitted`, `error`) que não corresponde ao ciclo de vida
real do pedido no Tiny. O usuário quer que a tela de listagem reflita o mesmo
vocabulário de status que o Tiny/Bling usa (aberto, aprovado, preparando
envio, faturado, pronto para envio, enviado, não entregue, dados incompletos,
cancelado), que o formulário de criação tenha campos adicionais vistos numa
referência visual (Natureza da operação, Número, Vendedor, Lista de preço,
endereço de entrega diferente) e que cada item da tabela de produtos aceite
um desconto em R$.

O visual deve seguir a identidade visual já existente do Honey (componentes
`table-card`, `status-pill`, `orders-table`, `field-input`, `btn-export` etc.)
— não é para clonar o layout do Bling pixel a pixel, só a estrutura funcional.

## Decisões (confirmadas com o usuário)

1. **Status sincronizado automaticamente do Tiny.** Não é o usuário que muda o
   status manualmente — um job periódico consulta o Tiny e atualiza.
2. **Desconto por item é valor fixo em R$**, não percentual.
3. **"Natureza da operação" é o mesmo campo que hoje é o radio
   Pedido Comum/Transferência de Estoque** (`kind`), só muda pra um `select`.
4. **"Vendedor" é campo de texto livre**, sem vínculo com usuários do sistema.
5. **Abas de status**: por padrão só aparecem "Todos", "Aberto" e "Aprovado".
   As demais (Preparando Envio, Faturado, Pronto para Envio, Enviado, Não
   Entregue, Dados Incompletos, Cancelado) ficam escondidas atrás de um botão
   "mais", e só aparecem quando o usuário clica.
6. Lista de preço "Transferência" só afeta o preço sugerido de itens
   adicionados **depois** de trocar a lista — não recalcula itens já
   existentes na tabela.
7. Colunas "Previsto" e "Data limite de despacho" do Bling **não** entram —
   exigiriam campos novos não pedidos.
8. Endereço de entrega diferente revela um bloco padrão de endereço BR (rua,
   número, complemento, bairro, cidade, UF, CEP) — assumido por analogia ao
   que já existe em `Client`/`Carrier`, já que a imagem de referência só
   mostra o checkbox desmarcado.

## 1. Status do pedido

### Enum novo (substitui o atual)

```ruby
enum :status, {
  aberto: 0, aprovado: 1, preparando_envio: 2, faturado: 3,
  pronto_para_envio: 4, enviado: 5, nao_entregue: 6,
  dados_incompletos: 7, cancelado: 8
}
```

Migração de dados dos valores antigos://
- `draft` (0), `saved` (1), `transmitted` (2) → `aberto` (0)
- `error` (3) → `dados_incompletos` (7)

`dados_incompletos` passa a ter duplo uso: (a) o Tiny pode reportar essa
situação pra um pedido já existente lá, e (b) é o status local quando o envio
pro Tiny falhou antes de existir `tiny_reference_id`.

### Envio automático ao salvar

- O botão "Salvar Rascunho" sai. Sobra só "Salvar", que exige cliente/local de
  transferência + itens (igual à validação de hoje quando `!draft?`).
- Ao salvar com sucesso, o controller dispara `TransmitB2bOrderJob` automaticamente
  (sem precisar de clique manual). O botão "Transmitir" na listagem sai.
- `TransmitB2bOrderJob` continua chamando `B2bTinyService`, mas agora:
  sucesso → `status: :aberto` (mais `tiny_reference_id/number`);
  falha → `status: :dados_incompletos`, guarda `error_message`.
- Na listagem, quando `status == dados_incompletos && tiny_reference_id.blank?`,
  aparece um botão "Reenviar" que dispara o mesmo job de novo.

### Sincronização periódica

- `B2bTinyService#order_status(tiny_reference_id)` — novo método, chama
  `pedido.obter.php` (mesmo endpoint que `Tiny::Orders.obtain_order` já usa
  pra outro fluxo) e devolve a `situacao` (string do Tiny) e, se vierem no
  payload, código de rastreamento.
- Mapa de tradução `situacao` (Tiny) → enum:
  `'Aberto' => :aberto, 'Aprovado' => :aprovado, 'Preparando Envio' =>
  :preparando_envio, 'Faturado' => :faturado, 'Pronto para Envio' =>
  :pronto_para_envio, 'Enviado' => :enviado, 'Não Entregue' => :nao_entregue,
  'Cancelado' => :cancelado, 'Dados Incompletos' => :dados_incompletos`.
  Situação desconhecida/não mapeada é ignorada (mantém o status atual).
- `SyncB2bOrdersStatusJob` novo: itera `B2bOrder.where.not(tiny_reference_id: nil)`,
  chama `order_status`, atualiza `status` (e `tracking_code` se vier).
- Plugado como mais um passo dentro do `MakeCsvDataJob` existente (mesmo
  padrão de `Motor`/log dos outros syncs), pra rodar no mesmo cron externo
  que já está configurado — sem precisar de infra nova.

## 2. Formulário de criação (`_form.html.erb`)

Seção "Dados do Pedido" reorganizada em 2 colunas, igual à referência:

| Campo | Tipo | Observação |
|---|---|---|
| Natureza da operação | `select` (Atacado / Transferência de Estoque) | mesmo campo `kind`, troca de radio pra select |
| Número | texto somente-leitura | `@b2b_order.id` ou "Gerado automaticamente" se novo |
| Cliente | (já existe) | sem mudança |
| Vendedor | texto livre | novo campo `salesperson_name` |
| Lista de preço | `select` (Padrão / Transferência) | novo campo `price_list`, enum |
| checkbox "endereço de entrega diferente" | boolean | novo campo `different_shipping_address`, revela bloco de endereço |

O toggle de exibir Cliente vs. Local de Destino continua igual, só que agora
disparado pelo `onchange` do select em vez do radio.

## 3. Desconto por item

- Nova coluna `discount` (decimal 10,2, default 0) em `b2b_order_items`.
- Nova coluna "Desconto" na tabela de itens (form e JS de adicionar item via
  planilha/modal — inicia em 0).
- Total da linha = `(price - discount) * quantity` (não permite ficar negativo).
- Ao montar o payload pro Tiny, `valor_unitario` vai líquido (`price - discount`).

## 4. Preço por Lista de preço

- `search_product`, `product_picker` e `parse_items_spreadsheet` passam a
  devolver também o preço "normal" do produto (`product.price`), além do
  `suggested_price` (o `* 0.4` de hoje).
- No JS, ao adicionar um item, o preço usado é escolhido conforme o valor
  atual do select "Lista de preço": `Padrão` → `suggested_price`,
  `Transferência` → preço normal.

## 5. Tela index

- Barra de busca por cliente (nome/razão social) ou número do pedido
  (`params[:q]`).
- Abas: Todos, Aberto, Aprovado sempre visíveis, com contagem por status
  (contagem calculada sobre o escopo já filtrado por busca, sem aplicar o
  filtro de status, igual ao comportamento do Bling).
- Botão "mais" que revela (via JS, sem reload) as abas restantes: Preparando
  Envio, Faturado, Pronto para Envio, Enviado, Não Entregue, Dados
  Incompletos, Cancelado.
- Colunas da tabela: Nº, Data, Cliente, CNPJ/CPF, Total, Nº pedido (Tiny),
  Rastreamento, Status, Ações.
- `Total` calculado a partir da soma das linhas dos itens
  (`B2bOrder#total`, novo método).

## Fora de escopo

- Sincronizar/editar o pedido no Tiny a partir de mudanças feitas na
  listagem do Honey (via só acontece Honey → Tiny na criação/reenvio).
- Colunas "Previsto" / "Data limite de despacho".
- Aba "Entregue" (Tiny tem, mas não foi pedida).
- Recalcular preços de itens já adicionados quando a Lista de preço muda.

## Migrações necessárias

1. Alterar dados do enum `status` de `b2b_orders` (remap 0/1/2/3 → 0/.../7).
2. Adicionar em `b2b_orders`: `salesperson_name:string`,
   `price_list:integer default 0`, `different_shipping_address:boolean default false`,
   `shipping_street/number/complement/neighbourhood/city/state/zip:string`,
   `tracking_code:string`.
3. Adicionar em `b2b_order_items`: `discount:decimal precision 10 scale 2 default 0`.

## Testes

- `test/models/b2b_order_test.rb`: novo enum, validações de endereço quando
  `different_shipping_address`.
- `test/controllers/b2b_orders_controller_test.rb`: criação dispara o job de
  transmissão; índice filtra por status/busca; contadores das abas.
- `test/services/b2b_tiny_service_test.rb`: `order_status` mapeando situação.
- Novo `test/jobs/sync_b2b_orders_status_job_test.rb`.
