# Catálogos B2B — Design

Data: 2026-10-08

## Objetivo

Montar catálogos de produtos no Honey (mesmo seletor do pedido B2B, sem frete/preço), publicar uma
página pública muito bonita (linha Gymshark) em que o lojista escolhe modelos, cores e tamanhos e
envia uma **encomenda**, e transformar a encomenda em pedido de venda B2B. O catálogo também gera um
PDF para mandar ao cliente. **Sem preço** em nenhum lugar do catálogo: o preço vai depois, no
romaneio.

## Tipos de catálogo

- **Geral:** um link para vários lojistas. Quem abre se identifica com **Nome e CNPJ**; cada CNPJ tem
  uma encomenda no catálogo.
- **Por cliente:** vinculado a um `Client` do Honey. O link é dele e abre direto a encomenda dele.

## Dados

- `b2b_catalogs`: `title`, `kind` (`general`/`client`), `client_id` (opcional), `status`
  (`active`/`closed`), `public_token` (aleatório, 32+ chars, único, regenerável), `notes` (texto
  para o cliente), `user_id` (quem criou), `stock_refreshed_at`, timestamps.
- `b2b_catalog_products`: um por **cor** (= produto do Shopify). `b2b_catalog_id`,
  `shopify_product_id`, `model_name`, `color_name`, `position`, `image_urls` (JSON, todas as fotos
  do Shopify), timestamps.
- `b2b_catalog_variants`: um por **tamanho**. `b2b_catalog_product_id`, `sku`, `size`, `position`,
  `available` (inteiro, interno), `availability` (`available`/`low`/`sold_out`), timestamps.
- `b2b_catalog_orders` (encomendas): `b2b_catalog_id`, `customer_name`, `customer_registration`
  (CNPJ só dígitos; único por catálogo), `client_id` (quando casa com um `Client`), `status`
  (`new`/`seen`/`converted`), `b2b_order_id` (quando convertida), `submitted_at`,
  `last_edited_by` (`customer` ou nome do usuário do Honey), `edit_token` (aleatório, guardado em
  cookie para o lojista reabrir sem digitar o CNPJ de novo), timestamps.
- `b2b_catalog_order_items`: `b2b_catalog_order_id`, `b2b_catalog_variant_id`, `quantity`.

## Agrupamento Modelo / Cor

Cada produto do Shopify é uma cor; `option1` é o tamanho; a cor é o fim do nome
("Legging Apex Seamless **Ash**", "Legging Pure Seamless **Tibetan Red**").

`B2bCatalogs::NameSplitter.split(names) -> { name => [model, color] }`: entre os nomes escolhidos,
produtos que compartilham o mesmo prefixo de palavras com pelo menos outro produto formam um modelo
(maior prefixo comum do grupo); o resto é a cor. Produto sem par: modelo = nome sem a última palavra,
cor = última palavra. Na tela de montagem os dois campos são **editáveis**.

## Montagem (Honey)

Pedidos B2B → **Catálogos** (tela/permissão nova `b2b_catalogs`, grupo Pedidos B2B).

- Lista: título, tipo, cliente, status, nº de encomendas com **badge de novas**, atualização do
  estoque.
- Formulário: título, tipo, cliente (se por cliente), observação; seletor de produtos igual ao do
  pedido B2B — escolher qualquer tamanho adiciona a cor inteira com todos os tamanhos. Modelos e cores
  sugeridos e editáveis, ordenação (subir/descer), remover cor.
- Ações: **copiar link**, **abrir página**, **baixar PDF**, **encerrar/reabrir**, **gerar novo link**.
- Ao salvar, o estoque e as fotos do catálogo são atualizados na hora (job em background).

## Estoque e fotos (a cada 1 hora)

`B2bCatalogRefreshJob` (rake `b2b_catalogs:refresh`, Heroku Scheduler **a cada 1 hora**):
- Para cada SKU distinto dos catálogos `active`: disponível = `B2bStockAvailability` (Correios B2B −
  reservas da fila), consultas em paralelo como já é feito. `availability`: `sold_out` se ≤ 0, `low`
  se ≤ 5, senão `available`. Falha do Correios num SKU mantém o valor anterior.
- Para cada `shopify_product_id` distinto: lista de imagens do Shopify (todas, em ordem). Falha
  mantém as anteriores; sem nenhuma, usa `Product#image_url`; sem nada, placeholder.
- Grava `stock_refreshed_at` no catálogo.

## Página pública

`/catalogo/:token` — sem login (único controller público do app), layout próprio, tema **claro**.

Visual (linha Gymshark): tipografia forte em caixa alta, muito espaço em branco, fotos grandes
(proporção retrato), cards sem borda com hover que troca para a 2ª foto, **bolinhas de cor**
(swatch com a foto recortada da cor), pílulas de tamanho, barra fixa inferior. Animações suaves:
entrada dos cards em cascata, transição ao trocar cor, contador de peças pulsando, confirmação
animada ao enviar. Mobile-first.

- Capa: título + observação + data da última atualização do estoque.
- Grade de modelos; trocar cor troca foto e tamanhos. Abrir o modelo: galeria com todas as fotos da
  cor, pílulas de tamanho com estado `disponível` / `últimas unidades` / `esgotado` (riscado,
  desabilitado) e campo de quantidade (± e digitação) **limitado ao disponível**. Número exato do
  estoque nunca aparece.
- Barra fixa: "N peças selecionadas" + **Enviar encomenda**; painel de resumo (modelo, cor, tamanho,
  quantidade, editar/remover).
- **Geral:** antes de enviar, Nome + CNPJ (validação de dígitos verificadores). Mesmo CNPJ reabre a
  encomenda existente (edição). Cookie com `edit_token` reabre direto no mesmo navegador.
- **Por cliente:** abre a encomenda do cliente (criada na 1ª visita).
- Encomenda **pode ser alterada até virar pedido**. `converted`: mostra "Encomenda recebida — em
  andamento" e bloqueia edição. Catálogo `closed`: mostra "Catálogo encerrado".
- O servidor revalida tudo ao enviar: variantes do próprio catálogo, quantidade ≥ 0 e ≤ disponível,
  CNPJ válido.
- Envio/alteração pelo cliente volta o status para `new` (aparece de novo como novidade).

## Encomendas no Honey

Dentro do catálogo:
- Lista: cliente, CNPJ, data, total de peças, status (`nova` → `vista` → `convertida`), quem alterou
  por último. Abrir marca `vista`.
- **Contador de novas** no menu (Pedidos B2B → Catálogos) e na lista de catálogos.
- **Editar a encomenda** pelo Honey (antes de converter): quantidades, remover itens, adicionar
  cores/tamanhos do catálogo. Grava `last_edited_by` com o usuário. A cliente vê a versão alterada.
- **Criar pedido:** abre o formulário normal de **pedido de venda B2B** pré-preenchido com os itens
  (SKU, nome, quantidade) e o cliente (se o CNPJ casar com um `Client`). Preço sugerido como hoje,
  bloqueio por estoque/reserva normal. Ao salvar, encomenda `converted` + `b2b_order_id`.

## PDF do catálogo

Prawn (padrão do `B2bRomaneioPdf`): capa (título, observação, data), depois cada modelo com a foto
principal de cada cor, nome do modelo, cores e tamanhos disponíveis **no momento da geração**, sem
preço; última página com link e **QR code** para a página pública (gem nova `rqrcode`, que gera o
QR em PNG sem dependências nativas). Fotos baixadas com timeout; falha vira placeholder.

## Fora do escopo

- Preço no catálogo/encomenda.
- Reservar estoque pela encomenda (só o pedido reserva, ao entrar na fila do Tiny).
- E-mail de aviso.

## Testes

- Models e validações (token único, CNPJ, encomenda única por CNPJ/catálogo).
- `NameSplitter` com nomes reais ("Tibetan Red", produtos sem par).
- Refresh job: disponível/nível, falha do Correios mantém valor, fotos do Shopify (mockado).
- Página pública: geral (identificação, reabrir por CNPJ), por cliente, limite de estoque, edição,
  catálogo encerrado, encomenda convertida, token inválido → 404.
- Honey: montagem, editar encomenda, contador de novas, criar pedido pré-preenchido, conversão.
- PDF: gera e contém modelos/cores, sem preço.
