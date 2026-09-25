# Sistema de Chamados (Tickets) — Design

Data: 2026-09-25

## Objetivo

Permitir que qualquer usuário abra chamados para uma área de responsabilidade, com
responsáveis fixos, prazo de resposta (SLA) por vez, interações com prints, mudança de
status pelas interações e notificações por e-mail bonitas e descritivas para todas as
partes envolvidas.

## Decisões (confirmadas com o usuário)

- Responsabilidade = cadastro `TicketResponsability` (grafia escolhida pelo usuário) com
  **vários usuários responsáveis fixos**.
- **Todos os usuários abrem chamados**. Em `/` cada um vê os chamados em que participa;
  admin pode ver todos.
- **Prazo por vez**: reinicia a cada interação e vale para quem está com a vez; chamado
  vencido fica destacado e gera um e-mail de "prazo estourado" (uma vez por vencimento).
- Acompanhante conta como **lado do responsável** na regra do prazo.
- Status muda **pelas interações**; marcar `resolved` exige texto de solução.
- Prints/anexos na abertura e nas interações via **Active Storage + Bucketeer** (já
  configurado em `config/storage.yml`).
- E-mail via **add-on Mailtrap da Heroku (Sandbox)** — os e-mails ficam na inbox do
  Mailtrap, não chegam aos destinatários reais.
- Admin pode desativar as notificações por e-mail de qualquer usuário.
- Sem commits automáticos; implementação direto na `master`.

## Modelo de dados

### `ticket_responsabilities`
| coluna | tipo | notas |
|---|---|---|
| name | string, not null | único |
| description | text | |
| response_time_hours | integer, not null | > 0, horas corridas |
| active | boolean, default true, not null | inativas não aparecem ao abrir chamado |

### `ticket_responsability_users`
`ticket_responsability_id`, `user_id` (FKs, índice único no par).

### `tickets`
| coluna | tipo | notas |
|---|---|---|
| title | string, not null | |
| description | text, not null | |
| ticket_responsability_id | FK, not null | |
| requester_id | FK users, not null | quem abriu |
| status | integer (enum), not null | ver abaixo |
| due_at | datetime | prazo da vez atual; nulo quando resolvido/fechado |
| overdue_notified_at | datetime | zera a cada nova interação/mudança de vez |
| solution | text | preenchida ao resolver |
| resolved_at | datetime | |
| closed_at | datetime | |
| last_activity_at | datetime | ordenação da lista |

Índices: `status`, `due_at`, `requester_id`, `ticket_responsability_id`.
`has_many_attached :attachments`.

### `ticket_participants`
`ticket_id`, `user_id`, `role` (enum: `requester`, `responsible`, `follower`), índice único
em `[ticket_id, user_id]`. Na abertura os responsáveis da responsabilidade são **copiados**
aqui (snapshot) — alterar a responsabilidade não afeta chamados existentes.

### `ticket_messages`
| coluna | tipo | notas |
|---|---|---|
| ticket_id | FK, not null | |
| user_id | FK users | nulo para eventos de sistema |
| body | text | pode ser vazio se houver só mudança de status/anexo |
| kind | integer enum: `comment`, `event` | `event` = "X chamou Y para acompanhar" (não usar `system`: colide com Kernel#system) |
| status_from / status_to | integer | nulos quando não houve mudança |

`has_many_attached :attachments`. Validação: uma mensagem `comment` precisa ter body,
anexo ou mudança de status.

### `users.ticket_notifications_enabled`
boolean, default true, not null.

## Status e regra de prazo

Enum `Ticket.status`: `awaiting_responsible` (0), `awaiting_requester` (1),
`in_progress` (2), `resolved` (3), `closed` (4). Abertos = 0,1,2.

- Abertura: `awaiting_responsible`, `due_at = agora + response_time_hours`.
- Interação sem mudança explícita de status:
  - autor é o solicitante → `awaiting_responsible`;
  - autor é responsável, acompanhante ou admin não-solicitante → `awaiting_requester`;
  - em ambos os casos `due_at = agora + prazo`, `overdue_notified_at = nil`.
  - Interação em chamado `resolved`/`closed` sem escolher status não reabre (só comenta).
- Interação com mudança explícita:
  - para status aberto → `due_at = agora + prazo`, zera `overdue_notified_at`,
    `resolved_at`/`closed_at` ficam nulos;
  - para `resolved` → body obrigatório (rotulado "Solução"), copia para
    `tickets.solution`, `resolved_at = agora`, `due_at = nil`;
  - para `closed` → `closed_at = agora`, `due_at = nil`.
- Permissões de status:
  - `resolved`: responsáveis, acompanhantes, admin;
  - `closed` e reabrir (sair de resolved/closed): solicitante e admin;
  - `in_progress`, `awaiting_*`: qualquer participante ou admin.
- `Ticket#overdue?` = aberto e `due_at < agora`. `Ticket#due_soon?` = aberto e vence em < 2h.
- "De quem é a vez": `awaiting_responsible`/`in_progress` → responsáveis;
  `awaiting_requester` → solicitante.

Toda a lógica de transição fica em um serviço `Tickets::AddMessage` (cria mensagem,
aplica status/prazo, registra participação do admin como `follower`, dispara notificação)
dentro de uma transação. Abertura em `Tickets::Create`. Adição de acompanhante em
`Tickets::AddFollower`.

## Acesso

- Ver/interagir em um chamado: participantes e admins. Admin não-participante que
  interage vira `follower`.
- Adicionar acompanhante: qualquer participante ou admin; usuários ativos que ainda não
  participam.
- CRUD de responsabilidades: somente admin.
- Ticket de uma responsabilidade inativa não pode ser aberto.
- Toggle de notificação em usuário: somente admin (campo em `admin_user_params`).

## Notificações

`TicketNotifier` decide destinatários e chama `TicketMailer.<evento>.deliver_later`
(Sidekiq). Destinatários sempre filtrados por `active` e `ticket_notifications_enabled`;
e-mails em branco são ignorados. Um e-mail por destinatário (personalizado: "você é o
responsável", "você é o solicitante", "você acompanha").

| Evento | Destinatários |
|---|---|
| `opened` | solicitante + responsáveis + acompanhantes iniciais |
| `new_message` | todos os participantes exceto o autor |
| `follower_added` | somente o novo acompanhante (a mensagem de sistema na timeline não gera e-mail para os demais) |
| `overdue` | quem está com a vez; se a vez é dos responsáveis, também o solicitante |
| `status_changed` para resolved/closed | coberto por `new_message` (o e-mail destaca a mudança de status e a solução) |

### Detecção de atraso
Rake `tickets:notify_overdue` → `TicketOverdueJob.perform_now`: busca chamados abertos com
`due_at < agora` e `overdue_notified_at IS NULL`, notifica e grava `overdue_notified_at`.
Agendado no **Heroku Scheduler** a cada 10 minutos (configuração manual do usuário).

## E-mails

- `ApplicationMailer` default `from: ENV.fetch('MAILER_FROM', 'chamados@chaseorders.com')`.
- Layout próprio `layouts/ticket_mailer.html.erb`: HTML com tabelas e CSS inline,
  largura máx. 600px, logo da Chase no topo, faixa colorida conforme status, card de
  resumo (nº, título, responsabilidade, status, prazo formatado em pt-BR + "em X horas",
  solicitante, lista de notificados), bloco de conteúdo (descrição/mensagem/solução),
  indicação de anexos ("📎 N anexos — veja no chamado"), botão "Ver chamado" e rodapé
  com o motivo do recebimento e como desativar (falar com admin). Versão `.text.erb` para
  cada e-mail.
- Assuntos: `[Chamado #123] Novo: <título>`, `[Chamado #123] Nova interação de <nome>`,
  `[Chamado #123] Você foi adicionado como acompanhante`, `[Chamado #123] ⚠ Prazo vencido`,
  `[Chamado #123] Resolvido`.
- Previews em `test/mailers/previews/ticket_mailer_preview.rb`.
- Horários no time zone da app (`Brasilia`).

### Mailtrap (Heroku Sandbox)
`config/initializers/mailtrap.rb` (define o módulo `MailtrapSandbox` e aplica via `ActiveSupport.on_load(:action_mailer)`): se `Rails.env.production?` e `MAILTRAP_API_TOKEN`
presente, busca `https://mailtrap.io/api/v1/inboxes.json` (Bearer token, `RestClient`) e
configura `delivery_method = :smtp` com username/password/domain/`smtp_ports[0]` da
primeira inbox, `authentication: :plain`. Falha na API → log de erro, boot continua.
`default_url_options = { host: ENV['APP_HOST'], protocol: 'https' }` em produção.
Dev continua com o SMTP local atual (porta 1025).

## Anexos

- Active Storage no serviço `bucketeer` (já configurado); bucket privado → links via
  `rails_blob_path` (redirect assinado).
- Tipos: png, jpg/jpeg, gif, webp, pdf. Máx. 10 MB por arquivo, 10 arquivos por envio.
  Validação no model.
- Script inline no partial `tickets/_attachments_field` (padrão do projeto, sem Stimulus): input múltiplo, arrastar e soltar, **colar print com
  Ctrl+V**, pré-visualização com remover antes de enviar.
- Exibição: miniaturas (img com CSS, sem `image_processing`) que abrem modal; PDFs como
  link com ícone.

## Telas

- **Menu**: novo item "Chamados" (todos os usuários) → `/`. "Responsabilidades" dentro
  do grupo Usuários (admin).
- **`/` (home#index)**: cards de contagem (Aguardando você, Aguardando outros, Vencidos,
  Resolvidos nos últimos 7 dias); tabela paginada (`will_paginate`) com nº, título,
  responsabilidade, status (badge), prazo (vermelho vencido / amarelo < 2h), última
  atividade; filtros: status, responsabilidade, papel (solicitante/responsável/
  acompanhante) e, para admin, escopo "Todos". Botão "Abrir chamado".
- **`tickets#new`**: select de responsabilidade (ao escolher, mostra descrição, prazo e
  responsáveis via data-attributes), título, descrição, anexos, acompanhantes opcionais.
- **`tickets#show`**: cabeçalho com status, prazo (contagem), de quem é a vez e solução
  em destaque quando resolvido; descrição e anexos originais; timeline de mensagens
  (comentários, eventos de sistema, mudanças de status, anexos); formulário de interação
  com textarea, anexos e select "Alterar status" (só opções permitidas ao usuário; ao
  escolher Resolvido, rótulo vira "Solução" e fica obrigatório); lateral com
  participantes por papel e formulário "Chamar pessoa".
- **`ticket_responsabilities`** (index/new/edit/destroy): nome, descrição, prazo em
  horas, responsáveis (multi-select), ativo. Destroy bloqueado se houver chamados —
  apenas desativar.
- **`users/_form`** (admin): checkbox "Receber notificações de chamados por e-mail";
  coluna/ícone na listagem de usuários.

Estilo segue os SCSS existentes em `app/assets/stylesheets/admin/pages/` (novo
`_tickets.scss`).

## Rotas

```ruby
resources :ticket_responsabilities, except: [:show]
resources :tickets, only: [:new, :create, :show] do
  resources :ticket_messages, only: [:create], path: 'messages'
  resources :ticket_participants, only: [:create], path: 'participants'
end
```

## Erros e bordas

- Envio de e-mail falha → retry padrão do Sidekiq; não afeta a transação da interação
  (notificação disparada após commit).
- Responsabilidade sem responsáveis ativos → não pode ser selecionada (validação: pelo
  menos um responsável).
- Usuário desativado continua no histórico, mas não recebe e-mails.
- Anexo inválido → erro de validação exibido no formulário, nada é salvo.

## Testes

Minitest (padrão do projeto), rodando no MySQL temporário:
- Models: validações, regra de prazo/status, `overdue?`, validação de anexos.
- Serviços: `Tickets::Create`, `Tickets::AddMessage` (transições, permissões, solução
  obrigatória, admin vira follower), `Tickets::AddFollower`.
- `TicketNotifier`: destinatários corretos, exclusão do autor, flag desligada, inativos.
- `TicketMailer`: assunto, destinatário, conteúdo principal.
- `TicketOverdueJob`: notifica uma vez só.
- Requests: acesso (participante/não participante/admin), CRUD de responsabilidades
  restrito a admin, toggle de notificação.

## Fora de escopo

- Entrega real de e-mails (add-on é sandbox).
- Horário comercial no cálculo do prazo.
- Notificações in-app/tempo real, edição/exclusão de mensagens, busca full-text.
