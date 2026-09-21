# Módulo de Notas Fiscais e Cadastro de Empresas (Pedidos B2B)

Data: 2026-09-20

## Objetivo

Dentro de Pedidos B2B, criar (1) cadastro de **Empresas** emissoras com todos os
dados necessários para emissão de NF-e, incluindo o certificado digital A1, e
(2) um módulo de **Notas Fiscais** que gera e assina o XML da NF-e a partir de
um pedido B2B. A geração é **manual**: o usuário clica no pedido e escolhe a
empresa emissora. Nenhum fluxo existente (transmissão ao Tiny, Correios) muda.

## Fora de escopo (explícito)

- Transmissão à SEFAZ (webservice, protocolo de autorização, consulta, cancelamento).
  Uma nota nunca passa de `assinada` por código desta entrega.
- NFS-e (serviço). Só NF-e de produto, modelo 55, layout 4.00.
- Regras fiscais avançadas (ICMS-ST, DIFAL, IPI, tributos da reforma tributária).
  Esta entrega usa a tributação padrão configurada na empresa.
- Garantia de aceitação pela SEFAZ: sem homologação real não é possível
  garantir. O XML é validado estruturalmente e a assinatura é verificada em
  teste com certificado de teste; a validação fiscal cabe a um contador.
- Vincular pedidos a uma empresa automaticamente (a empresa é escolhida a cada clique).

## Premissas

- Regime e CFOPs iniciais: venda 5102/6102, transferência 5152/6152 (dentro/fora da UF), editáveis por empresa.
- Uma nota ativa por pedido. Nova geração só é permitida se a anterior estiver
  em `erro`, `rejeitada` ou `cancelada`.

## 1. Menu e permissões

- Grupo do menu "Pedidos" renomeado para **Pedidos B2B**.
- Novos itens no grupo: **Empresas** (`companies`) e **Notas Fiscais** (`fiscal_notes`).
- Duas novas chaves em `Screen::DEFINITIONS`, no grupo 'Pedidos B2B' de `Screen::GROUPS`.
  Perfis existentes não recebem as permissões automaticamente.

## 2. Storage (Bucketeer) e criptografia

- Instalar Active Storage (tabelas).
- Novo serviço `bucketeer` em `config/storage.yml`, lendo `BUCKETEER_AWS_ACCESS_KEY_ID`,
  `BUCKETEER_AWS_SECRET_ACCESS_KEY`, `BUCKETEER_BUCKET_NAME`, `BUCKETEER_AWS_REGION`.
  Development e production usam `:bucketeer`; test continua `:test` (Disk).
  Os serviços antigos `amazon` (bucket fixo no código) deixam de ser referenciados.
- Arquivos privados; nenhuma URL pública é gerada. O certificado não é baixável.
- `ActiveRecord::Encryption` configurado por variáveis de ambiente
  (`ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`, `..._DETERMINISTIC_KEY`, `..._KEY_DERIVATION_SALT`),
  com chaves fixas apenas em test. **Ação do usuário:** cadastrar as variáveis no
  Heroku antes do deploy.
- `certificate_password` usa `encrypts` e entra em `filter_parameters`; nunca é
  renderizada nem logada.

## 3. Empresa (`Company`)

Campos:
- Identificação: `legal_name`, `trade_name`, `cnpj`, `state_registration` (IE),
  `municipal_registration` (IM), `cnae`, `tax_regime` (1 Simples, 2 Simples excesso, 3 Normal).
- Endereço: `street`, `number`, `complement`, `neighbourhood`, `city`,
  `city_ibge_code`, `state`, `zip`, `phone`, `email`.
- Emissão: `environment` (homologacao/producao), `nfe_series`, `next_nfe_number`.
- CFOP: `cfop_sale_in_state`, `cfop_sale_out_of_state`,
  `cfop_transfer_in_state`, `cfop_transfer_out_of_state`; `operation_nature_sale`,
  `operation_nature_transfer`.
- Tributação padrão: `icms_situation` (CSOSN/CST), `pis_cst`, `cofins_cst`.
- `active`.
- Certificado: `has_one_attached :certificate` (.pfx), `certificate_password` (criptografada),
  `certificate_expires_at`, `certificate_subject`, `certificate_cnpj`.

Regras:
- CNPJ válido e único. UF válida. Série/número inteiros positivos.
- No upload, `Nfe::Certificate` abre o PKCS#12 com a senha informada; senha errada
  ou arquivo inválido = erro de validação. Extrai validade e CNPJ do certificado;
  **recusa se o CNPJ do certificado diferir do da empresa**. Certificado vencido
  também é recusado.
- CRUD em `/companies` com aviso visual de certificado vencendo (≤ 30 dias) ou vencido.
  Editar sem reenviar arquivo mantém o certificado atual.

## 4. Nota fiscal (`FiscalNote`)

Campos: `company_id`, `b2b_order_id` (opcional), `number`, `series`, `access_key` (44),
`environment`, `operation_nature`, `cfop_summary`, `status`
(`rascunho`, `assinada`, `autorizada`, `rejeitada`, `cancelada`, `erro`),
`protocol`, `total_value`, `error_message`, `issued_at`, `has_one_attached :xml`.

Telas:
- `/fiscal_notes`: lista com filtros (status, empresa) e download do XML.
- `/fiscal_notes/:id`: detalhe (chave, empresa, pedido, status, erro).
- Botão **"Gerar nota fiscal"** nas listas de Pedidos de Atacado e Transferências
  (e na edição do pedido): abre a escolha da empresa (só ativas e com certificado
  válido) e dispara a geração.

## 5. Gerador (`app/services/nfe/`)

- `Nfe::Certificate`: carrega PKCS#12 (blob + senha), expõe chave privada, certificado,
  validade e CNPJ.
- `Nfe::XmlBuilder`: função pura. Entrada: empresa, destinatário, itens, número,
  série, natureza, data. Saída: XML `NFe/infNFe` (4.00, mod 55) e chave de acesso
  (cUF+AAMM+CNPJ+mod+série+nNF+tpEmis+cNF+DV módulo 11).
- `Nfe::Signer`: XMLDSig enveloped sobre `infNFe`, C14N inclusiva, SHA-1/RSA-SHA1
  (exigido pelo layout), `Reference URI="#NFe<chave>"`, X509Certificate no KeyInfo.
- `Nfe::Generator.call(order:, company:)`:
  1. valida empresa (ativa, certificado válido) e dados fiscais do pedido;
  2. escolhe CFOP por tipo do pedido (venda/transferência) e UF igual/diferente;
  3. dentro de transação com lock na empresa, reserva `next_nfe_number`, monta e
     assina o XML, cria a `FiscalNote` como `assinada` e anexa o XML;
  4. em qualquer falha a transação é desfeita: **número não é consumido**. Falha de
     dado fiscal gera erro claro (ex.: "NCM ausente para o SKU X"), sem XML incompleto.
- Nada no sistema chama o gerador além da ação manual de "Gerar nota fiscal".

## 6. Dados fiscais que faltam hoje

Migrations (colunas nullable) e campos nos formulários:
- `products`: `ncm`, `cest`, `origin` (padrão 0), `commercial_unit` (padrão `UN`).
- `clients`: `city_ibge_code`, `ie_indicator` (1 contribuinte, 2 isento, 9 não contribuinte).
- `transfer_locations`: `city_ibge_code`.

Destinatário: cliente (atacado) ou local de destino (transferência). Se o local for
uma empresa cadastrada, nenhuma regra especial nesta entrega.

## 7. Testes

- Empresa: validações, CNPJ, certificado (válido, senha errada, CNPJ divergente, vencido).
- `XmlBuilder`: chave e DV, campos obrigatórios, totais, CFOP por UF.
- `Signer`: verificação da assinatura com certificado autoassinado de teste.
- `Generator`: caminho feliz, dado fiscal ausente, rollback do número, nota duplicada.
- Controllers/telas: permissões, CRUD de empresas, lista/detalhe/download, botão e
  escolha de empresa, senha nunca exposta.
- Storage: serviço `bucketeer` lê as variáveis `BUCKETEER_*`.

## Riscos

- Assinatura XML é sensível a canonicalização; coberta por teste de verificação, mas
  só a SEFAZ confirma.
- Chaves de criptografia ausentes em produção impedem o boot; cadastrar antes do deploy.
- Rodar Active Storage em produção pela primeira vez exige a migration das tabelas.
