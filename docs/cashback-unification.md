# Unificação de cashback

A tela `/cashback_unifications` consulta dois cupons MTZ e mostra uma prévia antes de alterar a Shopify. Soma o cashback e a compra mínima e mantém o vencimento mais próximo, com seu horário original. O UNF é de uso único e exclusivo da cliente escolhida no cadastro do Honey.

Quando o MTZ está disponível para todos os clientes, a gerente precisa atestar que conferiu a titularidade. Isso não permite ignorar um vínculo existente com outra cliente. A prévia vale por dez minutos; a confirmação consulta novamente os dados e rejeita mudanças de valor, validade, público ou regras.

São aceitos cupons ativos, ainda sem uso reportado, em BRL, com valor fixo sobre a compra inteira, mínimo de compra em dinheiro e limite de um uso. Regras de combinação iguais são preservadas. Percentuais, múltiplos códigos no mesmo desconto, assinaturas, segmentos e restrições de produtos são recusados para não ampliar benefícios inadvertidamente. Um UNF não pode ser unificado novamente.

## Instalação e validação

- Executar a migração `20261014220000`. Ela cria o histórico e as reservas de cupons e libera `cashback_unifications` para o perfil Gerente (ID 2). Administradores já têm acesso; outros perfis podem receber a permissão pela tela existente.
- A integração usa o domínio B2C existente e `CHASE_ORDERS_TOKEN`. O token precisa de `read_discounts` e `write_discounts`. A API `2026-07` está fixada somente neste serviço, sem mudar a versão global das outras integrações.
- Testar em loja de desenvolvimento com cupons descartáveis antes da implantação. Não foram feitas mutações na loja real durante o desenvolvimento.
- Testes: `RAILS_ENV=test TEST_DATABASE_URL=mysql2://... bundle exec rails test test/services/cashback_unification_test.rb test/services/cashback_shopify_gateway_test.rb test/services/cashback_concurrency_test.rb test/controllers/cashback_unifications_controller_test.rb test/models/screen_test.rb`. Usar um banco exclusivo para testes; o teste de concorrência utiliza duas conexões e grava fora das transações de fixtures.

## Falhas e conferência administrativa

A Shopify não oferece uma transação única para substituir três descontos. O Honey grava os códigos originais, valores, vencimentos, cliente, responsável, atestado e código UNF reservado antes de começar. A reserva única por ID Shopify impede duas operações sobre o mesmo MTZ, inclusive entre processos diferentes. O status `processing` é confirmado no banco antes da primeira chamada externa.

O fluxo desativa e relê os originais; só depois cria e relê o UNF. Se houver erro antes de qualquer mutação, a operação fica `rejected` e libera as reservas. Se uma mutação foi tentada, falha ou resposta perdida deixa `needs_review`, mantendo as reservas. Um processo interrompido pode deixar `processing`; esse estado também bloqueia repetição. Não há reenvio ou reativação automática, pois uma requisição sem resposta pode ter sido aplicada pela Shopify.

Para uma operação parada, o administrador deve abrir os detalhes (etapa e código reservado são mostrados somente a ele) e o dev deve conferir os três códigos na Shopify. O registro `CashbackUnification` contém os snapshots completos e o `shopify_node_id` novo, quando recebido. A tela existente de alteração de status não pode reativar MTZ reservados.

1. Confirmar que nenhum worker ainda está executando a operação antes de intervir.
2. Consultar os dois MTZ e o UNF reservado, incluindo pedidos/usos e restrições de cliente. Não presumir que o UNF inexiste porque o ID não foi salvo.
3. Se o UNF existir corretamente e ambos os MTZ estiverem desativados, reconciliar o registro como concluído, mantendo as reservas dos originais e registrando a intervenção.
4. Se for necessário desfazer, primeiro garantir que nenhum UNF utilizável permaneça e que não houve uso; restaurar os MTZ com os vencimentos originais dos snapshots. Somente depois encerrar a operação e liberar as reservas. Não restaurar um cupom já vencido ou utilizado, nem estender sua validade.
5. Havendo uso ou situação incerta, manter o bloqueio até a conferência comercial. Não apagar o histórico nem liberar cupons apenas para contornar a mensagem.

O contador `asyncUsageCount` da Shopify é atualizado de forma assíncrona. As releituras reduzem a janela de risco, mas não garantem impedir um resgate simultâneo no checkout ou uma edição manual externa. Essa limitação da API precisa ser considerada na homologação e em qualquer recuperação.

Referências oficiais: [consulta por código](https://shopify.dev/docs/api/admin-graphql/2026-07/queries/codeDiscountNodeByCode), [desativação](https://shopify.dev/docs/api/admin-graphql/2026-07/mutations/discountCodeDeactivate), [criação do UNF](https://shopify.dev/docs/api/admin-graphql/2026-07/mutations/discountCodeBasicCreate), [contador de usos](https://shopify.dev/docs/api/admin-graphql/2026-07/objects/DiscountCodeBasic#field-DiscountCodeBasic.fields.asyncUsageCount).
