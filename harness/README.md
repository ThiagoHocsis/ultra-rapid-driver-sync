# O Harness

> Mecanismo de validação que permite que agentes de IA escrevam e refatorem código no
> motor de sincronização sem que a produção dependa da boa-fé do agente.

## A premissa

O harness clássico assume um autor humano: alguém que entende a intenção do código, erra
por distração e é corrigido em code review. Essa premissa quebra quando parte do código
chega de um agente.

Um agente otimiza para **"os testes passam"**, não para "o sistema está correto". Ele não
tem intenção de burlar nada — ele simplesmente não distingue as duas coisas. É por isso
que as soluções abaixo, todas plausíveis e todas verdes, são as regressões que este
harness existe para impedir:

| O agente faz | Fica verde? | O que quebra |
|---|---|---|
| Troca `aggregate_version < :v` por `<=` | Sim, na maioria das suítes | Idempotência: reaplicar o mesmo evento passa a reescrever |
| Reescreve o `UPDATE` condicional como ler → comparar em Ruby → escrever | Sim, sempre | Reintroduz a corrida entre leitura e escrita |
| Religa `use_transactional_tests` para estabilizar teste "flaky" de concorrência | Sim | A suíte de concorrência vira no-op |
| Importa a regra da Ultra-rápida dentro do núcleo pra "simplificar" | Sim | Núcleo deixa de ser agnóstico; fan-out quebra |
| Remove `aggregate_version` do payload de reconciliação por ser "redundante" | Sim | Snapshot antigo passa a sobrescrever evento novo |
| Marca o teste difícil como `pending` | Sim | A garantia some sem deixar rastro |
| Escreve `drivers.each { \|d\| d.profile }` | Sim | N+1 em caminho quente sob 300k registros |

Nenhuma dessas é pega por cobertura de linha. Várias **aumentam** a cobertura.

**A postura do harness é adversarial: ele não confia no autor, humano ou não.**

## As quatro camadas

**1. Propriedades, não exemplos.** Um teste de exemplo diz "para esta entrada, este
resultado" — e é satisfazível por especialização. Um teste de propriedade diz "para toda
entrada gerada, esta relação se mantém", e só é satisfazível implementando a regra.
Idempotência, convergência e monotonicidade são verificadas assim.
→ [`spec/properties/`](spec/properties/event_application_spec.rb)

**2. Concorrência de verdade.** Threads reais, conexões reais, barreira para soltá-las no
mesmo instante, e `use_transactional_tests = false` — sem isso o teste passa sem nunca ter
havido concorrência. Repetido com 5 seeds no CI, porque corrida é probabilística e uma
execução verde não é evidência.
→ [`spec/concurrency/`](spec/concurrency/concurrent_apply_spec.rb)

**3. Mutação, não cobertura.** Mutant altera o código deliberadamente e exige que a suíte
quebre. Mutante sobrevivente é uma mudança de comportamento que nenhum teste percebeu.
100% de cobertura no motor não significa nada se `<` puder virar `<=` sem quebrar nada — e
essa mutação específica destrói a idempotência.
→ gate `mutacao` no [CI](../.github/workflows/ci.yml)

**4. Fitness functions.** Testes sobre o código, não sobre o comportamento: o núcleo não
referencia consumidor, a guarda de versão está no `WHERE`, não há lock pessimista no
caminho quente, nenhum teste do núcleo está pendente, os testes de concorrência não rodam
sob transação. É a camada que fecha as saídas do quadro acima.
→ [`spec/guardrails/`](spec/guardrails/architecture_fitness_spec.rb)

## Rastreabilidade: princípio → mecanismo

Governança executável. Um princípio da [constituição](../.specify/memory/constitution.md)
sem mecanismo correspondente é considerado **violado** — e há um teste que verifica esta
própria tabela.

| Princípio | Mecanismo | Gate no CI |
|---|---|---|
| I — Idempotência estrita | propriedade `apply(e)^n == apply(e)`; dedup sob 16 threads | `propriedades`, `concorrencia` |
| II — Convergência sob desordem | toda permutação converge; versão nunca decresce; `occurred_at` ignorado sob clock skew | `propriedades` |
| III — Núcleo agnóstico | fitness: sem token de consumidor, sem HTTP síncrono no núcleo | `propriedades` |
| IV — Contrato antes de código | validação AsyncAPI/OpenAPI; detector de breaking change; exemplos do contrato executados | `contratos` |
| V — Elegibilidade na borda | recusa de PF com motivo e versão; inelegível não vai para DLQ | `propriedades` |
| VI — Degradação explícita | registro de clientes exige timeout/retry/breaker; full jitter obrigatório; teto de vazão no relay | `propriedades` |
| VII — Frescor verificável | TTL expirado remove do pool para todo par status×elegibilidade | `propriedades` |
| VIII — Autenticidade de evento | assinatura inválida rejeitada sem retry; varredura de PII por conteúdo | `contratos`, `estatica` |
| IX — Rastreabilidade | campos obrigatórios no envelope; métrica por motivo de descarte | `contratos` |
| Restrição — sem N+1 | `prosopite` em modo `raise`; cursor estável na reconciliação | `propriedades` |
| ADR-08 — reconciliação segura | snapshot antigo não sobrescreve evento novo; snapshot sem versão é recusado | `propriedades`, `concorrencia` |
| ADR-08 — outage e catch-up | simulação de outage de 2h com convergência e teto de vazão | `simulacao_dr` |

## Onde o humano continua entrando

O harness não elimina revisão — ele **realoca** a atenção humana para onde ela ainda é
insubstituível. Nos caminhos protegidos por [CODEOWNERS](../.github/CODEOWNERS) — núcleo,
harness, contratos e constituição — aprovação humana é obrigatória mesmo com a suíte
verde, porque é exatamente aí que se define o que "verde" significa.

Em todo o resto, o CI decide sozinho. Quando um agente abre vinte PRs por dia, a atenção
humana é o recurso que acaba primeiro, e gastá-la conferindo `includes` é desperdiçá-la.

## Nota sobre o código deste diretório

São **especificações executáveis, não uma suíte rodável**: descrevem os mecanismos com
precisão suficiente para serem implementados sobre a aplicação real, que não faz parte
desta entrega. Os nomes de classe (`Sync::EventApplier`, `Sync::DispatchPool`) referem-se
ao desenho descrito no [SDD](../README.md) e no
[modelo de dados](../specs/001-driver-sync-engine/data-model.md).
