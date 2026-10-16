# Atendimento WhatsApp no Honey

Implementação para desenvolvimento/homologação. Não publica serviços em produção e não conecta um número sem a leitura do QR no celular.

## Arquitetura e versão conferida

Base: Honey `ec8ebff`, Ruby 3.2.2, Rails 7.2.2.1, MySQL 8, Devise, Sidekiq 7.3.9/Redis, ERB e Bootstrap. Reutiliza sessão e perfis, `Screen` e `User#can_access_screen?`. Novas tabelas têm prefixo `whatsapp_`; os módulos atuais não são substituídos. A branch contém cashback; o módulo de ponto da instalação Windows não está neste checkout. Ao integrar essa instalação, mesclar rotas, menu, permissões e schema preservando suas alterações.

Provedor separado: **Evolution API 2.3.7**, tag `2.3.7`, commit `cd800f2976e1e5b682fbf86a01ee4d85ae61f370`, imagem publicada `evoapicloud/evolution-api:v2.3.7`. A imagem foi baixada e seu digest fixado em `sha256:1bd8afc4a6cf48822e6cf02469aeae7bd35a12a6b616eacd1291926307f4d339`. A execução local do provedor ficou pendente: a extração dessa imagem esgotou o disco de 32 GB deste executor; somente a cópia temporária da imagem foi removida, preservando bancos/volumes. Reserve espaço suficiente no host de homologação. A tag foi conferida no repositório e o workflow oficial publica tags `v<versão>`. A versão é marcada como release estável pela Evolution, mas inclui **Baileys 7.0.0-rc.9**. O pareamento requer homologação com os celulares; não representa garantia de compatibilidade permanente com o WhatsApp.

A documentação HTTP online estava indisponível durante a implementação. Os contratos foram conferidos diretamente no código da tag, em DTOs, schemas, rotas e emissores de eventos. Fontes:

- [Release 2.3.7](https://github.com/evolution-foundation/evolution-api/releases/tag/2.3.7)
- [Licença desta versão](https://github.com/evolution-foundation/evolution-api/blob/2.3.7/LICENSE)
- [Rotas de instância](https://github.com/evolution-foundation/evolution-api/blob/2.3.7/src/api/routes/instance.router.ts)
- [Criação/configuração da instância](https://github.com/evolution-foundation/evolution-api/blob/2.3.7/src/api/dto/instance.dto.ts)
- [Mensagens e mídias](https://github.com/evolution-foundation/evolution-api/blob/2.3.7/src/api/dto/sendMessage.dto.ts)
- [Webhooks e autenticação por cabeçalho](https://github.com/evolution-foundation/evolution-api/blob/2.3.7/src/api/integrations/event/webhook/webhook.controller.ts)
- [Eventos, histórico e download de mídia Baileys](https://github.com/evolution-foundation/evolution-api/blob/2.3.7/src/api/integrations/channel/whatsapp/whatsapp.baileys.service.ts)

A licença é descrita pelo fornecedor como Apache 2.0 **com condições adicionais**: não remover marca/copyright caso use o frontend deles e exibir aviso de uso da Evolution para administradores na documentação/configurações. O Honey utiliza somente o backend; inclui o aviso em “Números conectados” e neste documento. Revisar condições ao trocar versão. Não atualizar automaticamente para `latest` ou versões candidatas.

Este modo usa **Aparelhos conectados/Baileys, não a API oficial da Meta**. Pode exigir novo QR, sofrer incompatibilidades, restrições de sessão e bloqueios conforme regras do WhatsApp. A Cloud API oficial é uma alternativa futura, mas não substitui silenciosamente o pareamento solicitado. A interface acessa o adaptador `Whatsapp::Providers::Evolution`; outro adaptador deve implementar criação/conexão, estado, envio, histórico e download e normalizar seus eventos para `Whatsapp::Ingest`.

## Instalação do provedor, isolado do Honey

1. Preserve a instalação atual, `.env`, banco, volumes e as três chaves `ACTIVE_RECORD_ENCRYPTION_*`. Faça backup de acordo com a rotina existente. Não use `down -v`, `db:reset` ou `schema:load` em uma instalação existente.
2. Copie `deploy/whatsapp/.env.example` para `.env.whatsapp.local`. Gere duas chaves aleatórias próprias, sem espaços: uma para `EVOLUTION_API_KEY`, outra para `EVOLUTION_POSTGRES_PASSWORD` (ex.: `openssl rand -hex 32`). Não commite nem publique esse arquivo. Use a mesma chave do provedor em `WHATSAPP_EVOLUTION_API_KEY` no Honey.
3. Suba somente os serviços novos:

```sh
docker compose --env-file .env.whatsapp.local -f deploy/whatsapp/compose.yml up -d
docker compose --env-file .env.whatsapp.local -f deploy/whatsapp/compose.yml ps
```

O projeto Compose `honey-whatsapp-provider` cria seu próprio PostgreSQL, Redis e volume de sessões. Não utiliza ou apaga o MySQL/Redis do Honey. Não é necessário instalar o frontend Evolution Manager. PostgreSQL e Redis não publicam portas. A porta 8088 da Evolution fica em `127.0.0.1`, acessível apenas ao host; não a exponha à internet.

Se Honey e Evolution estiverem em containers separados, conecte apenas o web/worker à rede `honey-whatsapp-provider_provider`, sem alterar seus volumes. Dentro dela, use `http://evolution:8080`. Se Rails roda no host, use `http://127.0.0.1:8088`. No Windows, mantenha as configurações e os scripts locais; adapte somente a ligação de rede. Não substitua `compose.preview.yaml` da instalação atual.

O provedor precisa sair para os serviços do WhatsApp. O webhook precisa alcançar o Honey. Em homologação, use um endereço HTTPS válido em `WHATSAPP_WEBHOOK_BASE_URL`; não basta `localhost` visto de outro container. Pode ser uma URL interna resolvível na rede Docker para teste isolado sem exposição pública. Não publique chaves nos comandos, URLs, capturas de tela ou logs. Em ambiente cloud com rede restrita, liberar os destinos necessários pelo mecanismo de configuração autorizado; não contornar a política.

## Configurar o Honey e o worker

Adicionar as variáveis do exemplo ao mecanismo de segredos do **ambiente de homologação**. São configurações de servidor; a tela nunca envia chave de API ao navegador. `WHATSAPP_STORAGE_SERVICE` seleciona um serviço privado já definido em `config/storage.yml` (ex.: `local` com volume persistente compartilhado entre web/worker, ou `bucketeer`). Não usar bucket público.

Confirmar a conexão real do Rails antes de migrar. Neste repositório, `development` utiliza variáveis chamadas `PRODUCTION_DATABASE_*`. O nome do ambiente, sozinho, não comprova que o banco é de desenvolvimento. Use a configuração existente de homologação/preview com MySQL separado e confirme host/nome sem exibir senha.

Para criar um sandbox Rails novo, há o ambiente opcional `RAILS_ENV=whatsapp_preview`, que exige `HONEY_WHATSAPP_PREVIEW_DATABASE_URL` (`mysql2://.../honey_whatsapp_preview`) e recusa banco sem o sufixo `_whatsapp_preview`. Esse ambiente não usa as variáveis de banco de produção e desativa envio de email. Ele ainda precisa das variáveis de inicialização que o Honey já exige (veja o setup atual); usar valores de homologação e nunca importar dados/segredos de produção por conveniência. Configure `HONEY_WHATSAPP_PREVIEW_HOST` se usar um domínio diferente de localhost. Para o Honey Windows já configurado, manter o ambiente `preview` existente e aplicar somente a atualização incremental.

Em instalação já inicializada, aplicar a migração incremental `20261016180000_create_whatsapp_support.rb` com a rotina habitual (`bundle exec rails db:migrate`) no banco de homologação verificado. A migração apenas cria tabelas novas; não libera atendimento para todos. Administradores têm as permissões existentes de administrador; outros perfis devem receber as telas explicitamente.

Para um ambiente **novo e vazio de testes**, usar o schema base versionado e depois a nova migração. Há migrações antigas que tentam adicionar `last_shopify_sync_at` em duplicidade; isso impede reconstruir a aplicação inteira do zero por todas as migrações antigas. Não corrigir isso apagando/recriando um banco com dados.

Execute um worker separado, com as mesmas variáveis do Honey, a mesma conexão MySQL e o mesmo armazenamento privado:

```sh
bundle exec sidekiq -C config/sidekiq_whatsapp.yml
```

A fila `whatsapp` não é consumida pelo `config/sidekiq.yml` atual. O initializer dos jobs novos usa Sidekiq também em desenvolvimento; não basta iniciar só o servidor Rails. O Redis da fila deve ser o mesmo configurado no processo web e no worker. A Evolution tem seu próprio Redis e não é o Redis do Sidekiq.

Agende **a cada minuto** no ambiente correto:

```sh
bundle exec rails whatsapp:recover
```

Use o scheduler/cron da instalação, com as mesmas variáveis e usuário do worker. Esse job retoma eventos pendentes, filas de saída e download, identifica envios interrompidos e consulta o histórico armazenado pelo provedor. Sem scheduler, webhooks novos continuam chegando, mas a recuperação após interrupção fica incompleta. Não execute vários schedulers para o mesmo banco.

Recompile os assets pela rotina existente da instalação e reinicie web/worker. Os novos arquivos JS e CSS são assets Rails normais, carregados somente nas duas telas. Não é necessário trocar a pipeline global. Se houver CSP, permitir `img-src 'self' data:` para o QR PNG; mídias recebidas usam URLs do próprio Honey. Gravação de microfone exige HTTPS ou localhost e permissão explícita do navegador.

## Conectar primeiro e segundo número

1. Entre no Honey com a conta atual. No perfil, libere **Atendimento WhatsApp — Conversas** para atendentes e **Atendimento WhatsApp — Administrar conexões** para quem gerencia números. Administração de conexões não concede implicitamente acesso às conversas. Administradores do Honey têm acesso a todos os números.
2. Abra **Atendimento WhatsApp → Números conectados**. Informe “Vendas”, marque as pessoas autorizadas e clique **Adicionar número**.
3. Aguarde o QR real do provedor. No celular do primeiro número, abra **WhatsApp Business → Aparelhos conectados → Conectar aparelho** e escaneie. O QR expira e é atualizado por evento; o Honey oculta um QR com mais de 30 segundos. Se necessário, use **Conectar / renovar QR**.
4. Aguarde **Conectado** e confira o telefone retornado pelo WhatsApp. O Honey não usa o nome digitado como prova de qual telefone foi conectado.
5. Repita com outro nome, como “Atacado”, e **outro celular/número**. Cada registro possui identificador de instância e sessão independentes. Não use “Desconectar” no primeiro número para adicionar o segundo.
6. Abra **Conversas**. Ao responder, o número é o da conversa. Para iniciar uma conversa, escolha explicitamente um número autorizado e informe o telefone do cliente com país e DDD.
7. Para retirar um número, use **Desconectar** no cartão correspondente. Isso solicita logout daquela instância e bloqueia novos envios pelo Honey imediatamente; histórico e os outros números ficam preservados. Se o provedor estiver indisponível, a confirmação de logout fica pendente e a tela informa a falha. Tente novamente quando ele voltar.

Primeiro número indicado pelo usuário para homologação: **+55 11 5196-4815**. O segundo ainda precisa ser indicado. Nunca utilizar esses números em testes automatizados ou enviar mensagens reais sem a etapa de pareamento/validação acompanhada.

## Comportamento e limites

- Atendimento individual de texto, JPG/PNG/WEBP, PDF/TXT e áudio, até 10 MB por arquivo. Imagens e documentos aceitam legenda; para áudio, envie o texto separadamente. Tipos são conferidos pelos bytes, não apenas pelo nome/MIME informado. Gravação até 60 segundos quando MediaRecorder e o provedor suportarem o formato. Grupos, campanhas, robôs, IA, chamadas e disparos em massa ficam fora do módulo.
- A lista e a conversa consultam alterações a cada 4 segundos quando a aba está visível. Cada consulta revalida sessão, tela e autorização do número; não existe canal público de broadcast. Dois atendentes veem as mesmas atualizações. O histórico é paginado e preserva a posição quando o usuário lê mensagens anteriores.
- Assumir, transferir, encerrar e reabrir ficam registrados. Atribuição não impede outras pessoas autorizadas de ajudar. Uma mensagem nova recebida reabre a conversa; importação histórica não a reabre.
- Contatos existem sem Shopify. Telefones são normalizados sem alterar clientes. LIDs do WhatsApp não são tratados como telefone. PN alternativo confirmado pelo provedor pode identificar o contato; nomes e números ambíguos não mesclam cadastros. A vinculação a um cliente é explícita, e os pedidos só aparecem a quem já tem permissão.
- A recuperação inicial busca os últimos 7 dias **armazenados na Evolution**, não todo o histórico do celular. A sincronização seguinte retoma o último marco com sobreposição de cinco minutos. Até 10.000 registros por execução; exceder isso mantém o marco anterior e sinaliza `sync_limit_reached` para revisão. `messages.set` importa o lote de histórico que o WhatsApp efetivamente disponibilizar.
- A chave única de mensagens é `(connection_id, provider_id)`, com comparação binária. Eventos/recibos fora de ordem não reduzem um estado já confirmado. Envio pelo celular e eco de envio do Honey usam o mesmo identificador do provedor.
- `Na fila` e `Enviando` não são confirmação. `Enviada` requer retorno/eco do provedor; `Entregue`/`Lida` exigem recibo correspondente. Um erro após começar a requisição gera **Envio sem confirmação** e nunca provoca reenvio automático. O conteúdo continua no registro; um erro de transporte do navegador mantém o formulário e reutiliza a mesma chave de envio.
- Não há notas internas nesta entrega; nenhuma informação de responsável/transferência é enviada como mensagem ao cliente.

## Segurança e recuperação

Webhooks usam `X-Honey-Webhook-Token` diferente por conexão, comparado em tempo constante. A instância no caminho, envelope e conteúdo deve corresponder. A Evolution 2.3.7 permite cabeçalhos customizados, mas não fornece aqui uma assinatura HMAC nativa de corpo usada pelo módulo; o segredo compartilhado exige transporte protegido e acesso restrito. O endpoint não usa login de navegador. As demais rotas, inclusive JSON, usam Devise, CSRF, usuário ativo e autorização por número.

QR e tokens do webhook são cifrados com Active Record Encryption. Eventos guardam somente o conteúdo necessário e não persistem o `apikey` do envelope. Os parâmetros sensíveis são filtrados dos logs. O middleware limita webhooks a 2 MB, uploads a 11 MB e outras mutações do módulo a 64 KB antes do parser JSON/multipart. Configure também limites no proxy: webhook até 2 MB, upload até 11 MB. Eventos excessivos retornam 413 e precisam ser recuperados pelo histórico/página; monitorar isso durante homologação.

Os anexos são armazenados em chaves aleatórias do serviço privado, sem criar blobs públicos do ActiveStorage e sem retornar URLs do provedor. Download/imagem/áudio passam pela mesma checagem de acesso do histórico. SVG/HTML e formatos executáveis não são servidos. O webhook nunca pode ordenar que o Honey baixe uma URL arbitrária.

Saúde: a Evolution tem healthcheck HTTP e dependências PostgreSQL/Redis com probes. No Honey, **GET `/whatsapp/health`** exige administrar conexões e informa configuração, estados, último sync e filas/erros. Verificar também o worker Sidekiq e a execução do scheduler, além dos backups.

Em falha/reinício:

1. Reinicie serviços preservando volumes de PostgreSQL, Redis, sessões Evolution, MySQL e mídia Honey. `docker compose restart` não apaga os volumes. A sessão pode continuar válida, mas uma revogação pelo celular exige outro QR.
2. Verifique conectividade/health e retome o worker/scheduler. Use **Sincronizar** para uma conexão; eventos duplicados são absorvidos.
3. Eventos que falharam cinco vezes permanecem armazenados com `error_code`; corrija a causa e reenvie o job após zerar `attempts` administrativamente. Não marque eventos como processados sem conferir a causa.
4. Envios parados em `sending` há mais de dois minutos tornam-se `uncertain`. Consulte o celular e o histórico da Evolution antes de qualquer novo envio. Sem ID retornado não é possível inferir por texto que duas mensagens são a mesma: mensagens iguais podem ser legítimas. Nunca apague o marcador incerto para tentar novamente automaticamente.
5. Downloads têm no máximo quatro tentativas de comunicação, com orçamento e próximo horário persistidos no MySQL; reiniciar o worker ou executar a recuperação não zera esse limite. Mídia antiga pode já não estar disponível no WhatsApp; isso aparece como indisponível. Não substitua por um link público. Defina retenção/backup conforme política interna; esta entrega não apaga automaticamente conversas.
6. Backups devem incluir as chaves de criptografia de forma segura; perder as chaves inviabiliza ler tokens/QR/eventos cifrados. Não rotacione chaves apenas para instalar o módulo.

## Validação

Testes automatizados usam respostas simuladas do provedor e banco exclusivo de testes:

```sh
RAILS_ENV=test TEST_DATABASE_URL=mysql2://USUARIO:SENHA@HOST/BANCO_TESTE \
  bundle exec rails test test/services/whatsapp test/controllers/whatsapp
bundle exec rails zeitwerk:check
node --check app/javascript/whatsapp_support.js
```

Não apontar `TEST_DATABASE_URL` para dados reais. Os testes cobrem dois números, isolamento, acesso revogado, anexos privados, CSRF, eventos repetidos/fora de ordem, eco do celular, timeouts, recuperação, vínculo ambíguo e paginação. A validação real ainda depende do provedor acessível, webhooks alcançáveis e leitura do QR pelos dois celulares.

Resultado desta entrega em 16/10/2026: **95 testes, 429 asserções, zero falhas/erros** em Ruby 3.2.2, Rails 7.2.2.1 e MySQL 8. São 58 testes do módulo e 37 de regressão de cashback/permissões, incluindo a tela de pedidos filtrada pelo cliente. Comando completo:

```sh
bundle exec rails test test/services/whatsapp test/controllers/whatsapp \
  test/services/cashback_unification_test.rb test/services/cashback_shopify_gateway_test.rb \
  test/services/cashback_concurrency_test.rb test/controllers/cashback_unifications_controller_test.rb \
  test/models/screen_test.rb
```

Também passaram o carregamento Zeitwerk, a sintaxe JavaScript e a configuração Compose. No Chromium, foram verificadas as telas em 1440×1000 e 390×844, navegação móvel, painel de contato, seleção explícita de número, rascunho durante atualizações e resposta perdida do navegador reutilizando a mesma chave de envio. Não houve erro JavaScript. As telas usaram números e mensagens identificados como **SIMULAÇÃO**; não comprovam conexão real com o WhatsApp.

Roteiro real: conectar os dois números; enviar/receber texto, imagem, PDF e áudio em ambos; responder a um mesmo cliente nos dois; observar atualizações em duas sessões Honey; revogar o acesso de um atendente e tentar URL direta de anexo; reiniciar os serviços sem remover volumes; verificar retomada; desconectar apenas um número. Confirmar também login, CRM, pedidos, estoque, chamados, cashback e ponto na instalação que contém o módulo de ponto. Registrar resultados reais separadamente dos testes com simulação.
