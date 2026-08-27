# Constituição — Motor de Sincronização de Entregadores

> Este documento define os princípios inegociáveis do Motor de Sincronização entre o
> **Portal dos Entregadores** (system of record) e as **plataformas consumidoras** do
> ecossistema Magalu, sendo a Ultra-rápida a primeira delas.
>
> A constituição não é aspiracional. **Todo princípio aqui declarado tem um mecanismo
> executável correspondente no harness de CI** (ver `harness/`). Um princípio sem teste é
> considerado violado por definição — é essa amarração que permite que agentes de IA
> escrevam código no repositório sem que a produção dependa da boa-fé do agente.

## Core Principles

### I. Idempotência Estrita (NÃO-NEGOCIÁVEL)

Todo consumidor de evento deve ser seguro a reprocessamento. Aplicar o mesmo evento uma
ou N vezes produz exatamente o mesmo estado final do entregador e o mesmo conjunto de
efeitos colaterais observáveis.

O broker garante *at-least-once*, nunca *exactly-once*. Duplicata não é exceção: é o
comportamento normal do sistema sob rebalance de partição, timeout de commit de offset e
redrive de DLQ. Código que assume entrega única está errado, mesmo que passe em produção
por meses.

- Todo evento carrega `event_id` imutável (UUIDv7) gerado no ato da escrita no outbox.
- Efeitos colaterais externos (notificação, webhook, chamada a terceiros) só ocorrem
  atrás de uma barreira de deduplicação explícita.
- Reprocessar o histórico completo de um entregador desde a origem deve convergir para o
  mesmo estado atual.

*Protegido por:* teste de propriedade de idempotência (`apply(e)^n == apply(e)`).

### II. Convergência sob Desordem (NÃO-NEGOCIÁVEL)

A ordem de **chegada** dos eventos não determina o estado final. Apenas a ordem de
**emissão**, expressa por um contador monotônico por entregador, determina o estado final.

Eventos fora de ordem são inevitáveis: retentativa, particionamento, redrive de DLQ e
reconciliação concorrente reordenam a entrega. A defesa não é forçar ordem — é tornar a
ordem irrelevante.

- Todo evento carrega `aggregate_version`, monotônico e denso por `driver_id`, atribuído
  pelo Portal na mesma transação que muda o estado.
- A aplicação é condicional: um evento com versão menor ou igual à versão já persistida é
  descartado silenciosamente (com métrica), nunca aplicado.
- Nenhum campo de estado pode ser derivado de `occurred_at` ou da hora de chegada.
  Relógio de parede é telemetria, não é critério de ordenação.

*Protegido por:* teste de propriedade de convergência (qualquer permutação de uma
sequência de eventos converge para estado idêntico).

### III. Núcleo Agnóstico de Consumidor (NÃO-NEGOCIÁVEL)

O Portal dos Entregadores não conhece seus consumidores. Adicionar o consumidor N+1 ao
ecossistema não altera nenhuma linha de código do Portal, não altera seu schema e não
altera seu perfil de carga.

Isto é o que permite que a solução nasça agnóstica. Duas consequências operacionais:

- O Portal publica **fatos** em um contrato único. Ele não publica projeções, não filtra
  por consumidor e não roteia.
- A saúde de um consumidor nunca se propaga de volta ao Portal. Falha de consumo é
  resolvida no consumidor (retry do broker, DLQ, redrive), jamais por reenvio solicitado
  ao produtor.

*Protegido por:* fitness function de arquitetura — o pacote do núcleo não pode referenciar
nenhum identificador de consumidor.

### IV. Contrato Antes de Código

O schema do evento é a fonte da verdade, versionado e revisado independentemente da
implementação. Produtor e consumidor são validados contra o contrato, não um contra o
outro.

- Mudança incompatível exige nova versão major do tópico e período de convivência.
- Adicionar campo opcional é compatível; remover campo, renomear, estreitar tipo ou
  restringir enum não é.
- O contrato publicado é executável: valida payloads em CI dos dois lados.

*Protegido por:* validação de schema no CI + detector de breaking change no diff.

### V. Elegibilidade na Borda

O Portal emite fatos cadastrais. **Cada plataforma consumidora decide sozinha quem é
elegível a operar nela**, aplicando seus próprios critérios sobre esses fatos.

O Portal aprova o entregador para o ecossistema; a Ultra-rápida decide se ele pode receber
oferta de corrida. São decisões diferentes com donos diferentes. Empurrar elegibilidade
para o Portal o obrigaria a conhecer a regra de negócio de cada consumidor — violação
direta do Princípio III.

*Trade-off aceito:* a regra de elegibilidade fica distribuída entre consumidores, sem
ponto único de auditoria. Mitigado exigindo que toda decisão de elegibilidade seja
registrada com o motivo e a versão do agregado que a originou.

*Protegido por:* fitness function — nenhuma regra específica de consumidor no núcleo.

### VI. Degradação Explícita

Nenhum default implícito de biblioteca. Toda chamada externa declara, em código e por
escrito, seus quatro parâmetros de falha:

- **timeout** (conexão e leitura, separados)
- **política de retentativa**: exponential backoff **com full jitter**, teto de tentativas
- **circuit breaker**: limiar de abertura, janela e política de half-open
- **destino final da falha**: DLQ, descarte com métrica, ou fila de reconciliação

Retentativas nunca podem se acumular de forma sincronizada contra o system of record.
Recuperação de outage é evento de rebanho (*thundering herd*): jitter distribui o pico,
mas apenas vazão limitada impõe teto.

*Protegido por:* teste que falha se um cliente HTTP/broker for instanciado sem política
declarada.

### VII. Frescor Verificável

Estado sincronizado tem prazo de validade. Todo registro de entregador na plataforma
consumidora carrega `last_synced_at`, e um entregador cujo estado não é confirmado há mais
de `FRESHNESS_TTL` sai do pool de despacho — independentemente do status persistido.

Isto corrige uma assimetria perigosa do fail-closed. Na **ativação**, ausência de dado
significa negar oferta: é seguro. Na **inativação** — um bloqueio de segurança emitido
durante uma indisponibilidade — ausência de dado significaria manter ativo alguém que
deveria estar bloqueado: é inseguro. Não se pode fail-closed sobre um evento que nunca
chegou. A defesa é inverter o ônus: o entregador precisa *provar* que continua válido.

*Protegido por:* teste que assegura que entregador com `last_synced_at` expirado é
excluído do pool, mesmo com `status = active`.

### VIII. Autenticidade de Evento

Nenhum consumidor confia em payload por ele ter chegado pelo canal esperado. Autenticidade
e integridade são verificadas criptograficamente, e identidade de serviço é mútua.

- Transporte com mTLS; autenticação no broker via SASL/SCRAM com credencial por consumidor.
- Evento assinado na origem (JWS) — o consumidor rejeita evento cuja assinatura não valide
  contra a chave do Portal, mesmo vindo do tópico correto.
- Autorização por tópico: consumidor lê apenas o que lhe cabe; ninguém além do Portal
  produz no tópico de entregadores.
- Dados sensíveis (CPF, CNH, dados bancários) não trafegam em claro no evento. O evento
  carrega referência; o dado é buscado sob autorização, com criptografia em nível de campo
  e retenção mínima (LGPD).

*Protegido por:* teste de rejeição de evento com assinatura inválida + varredura de PII no
payload contra o schema.

### IX. Rastreabilidade Obrigatória

Um SLA que não se mede não existe. Todo evento carrega `event_id`, `correlation_id`,
`aggregate_version` e `occurred_at`, propagados de ponta a ponta.

- A latência de sincronização é medida como `applied_at - occurred_at`, com histograma
  por etapa (outbox → relay → broker → consumo → aplicação), permitindo atribuir violação
  de P99 a um componente específico.
- Todo descarte por versão obsoleta, toda rejeição por assinatura e toda mensagem enviada
  a DLQ emitem métrica com motivo. Silêncio não é sinal de saúde.

*Protegido por:* teste que falha se um evento for consumido sem propagar `correlation_id`.

## Restrições Técnicas

- **Stack do núcleo:** Ruby on Rails. Soluções que exijam runtime fora do domínio do time
  precisam de justificativa explícita de custo operacional no SDD.
- **Escala de referência:** ~300.000 entregadores ativos.
- **SLA de sincronização:** ≤ 30s P99 entre a escrita no Portal e o efeito na plataforma
  consumidora. Esse número é orçamento, não meta: cada etapa do caminho tem fatia
  declarada e monitorada.
- **Ciclo de vida coberto:** criação, ativação/inativação em tempo real, atualização de
  perfil.
- **Acesso a dados:** consultas em caminho quente não podem ser N+1. Varredura de base
  usa cursor estável `(updated_at, id)` — nunca `OFFSET`.

## Guardrails de Desenvolvimento com Agentes de IA

Parte-se do princípio de que código é gerado e refatorado por agentes (Claude Code,
Copilot, Gemini). O harness assume postura adversarial: ele não confia no autor, humano ou
não.

- **Testes são código protegido.** Enfraquecer, remover ou marcar como pendente um teste
  do núcleo de sincronização é uma mudança que exige revisão humana explícita — o CI
  detecta e bloqueia.
- **Cobertura não é evidência.** O núcleo é validado por mutation testing: código que
  passa nos testes mas está semanticamente errado é detectado como mutante sobrevivente.
- **Propriedades acima de exemplos.** As invariantes centrais (idempotência, convergência,
  monotonicidade) são verificadas por teste de propriedade sobre entrada gerada, não por
  casos escolhidos a dedo — um agente não consegue satisfazer o teste especializando-o
  para os exemplos.
- **Concorrência é testada de verdade.** Threads reais disputando o mesmo agregado, não
  simulação sequencial.
- **Arquitetura é testável.** Fitness functions impedem que um agente introduza acoplamento
  entre núcleo e consumidor, mesmo com todos os testes de unidade verdes.

## Governance

Esta constituição prevalece sobre qualquer outra prática do repositório. Em conflito entre
um princípio daqui e uma conveniência de implementação, o princípio vence ou é
formalmente emendado — nunca contornado no silêncio de um PR.

- **Todo princípio tem teste.** Um princípio sem mecanismo executável correspondente é
  considerado violado. A tabela de rastreabilidade princípio → teste é parte do SDD e é
  verificada no CI.
- **Emendas** exigem: justificativa escrita, avaliação de impacto nos contratos publicados,
  e plano de migração quando afetarem consumidores em produção.
- **Versionamento semântico** desta constituição: MAJOR para remoção ou redefinição
  incompatível de princípio, MINOR para novo princípio ou seção, PATCH para clarificação
  que não altera obrigação.
- **Revisão de PR** verifica conformidade constitucional explicitamente. Complexidade
  adicionada precisa ser justificada contra o princípio que ela serve.

**Version**: 1.0.0 | **Ratified**: 2026-08-27 | **Last Amended**: 2026-08-27
