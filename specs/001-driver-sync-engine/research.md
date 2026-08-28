# Decisões de Arquitetura e Trade-offs

Registro das decisões técnicas do Motor de Sincronização. Cada decisão declara o que foi
**rejeitado** e o que foi **aceito como custo** — uma decisão sem custo declarado é uma
decisão não examinada.

Referências entre colchetes apontam para os princípios da
[constituição](../../.specify/memory/constitution.md).

---

## ADR-01 — Publicação: outbox transacional com relay por polling

**Contexto.** A escrita de estado no banco do Portal e a publicação do evento precisam ser
atômicas [RF-02]. Publicar direto do controller após o `commit` cria uma janela em que o
processo pode morrer entre a transação e o `publish` — o Portal fica com um estado que
ninguém mais conhece, e o erro é silencioso e permanente.

**Opções.**

| Opção | Atômico? | Latência | Custo operacional |
|---|---|---|---|
| Dual-write (publica após commit) | **Não** | mínima | nenhum |
| Outbox + relay por polling | Sim | polling interval + publish | tabela + processo relay |
| Outbox + CDC (Debezium lendo o WAL) | Sim | sub-segundo | Kafka Connect, time que domine |
| Event sourcing no Portal | Sim | — | reescrita do system of record |

**Decisão.** Outbox transacional: a mudança de estado e a linha de evento são gravadas na
**mesma transação**; um processo relay lê a tabela e publica no broker, marcando a linha
como publicada. Polling a cada **1s**, em lotes, com `SKIP LOCKED` para permitir múltiplos
relays sem disputa.

**Por que não CDC agora.** Debezium é tecnicamente superior — elimina a carga de polling e
reduz latência para a casa dos milissegundos. Foi rejeitado nesta fase por custo
operacional: exige Kafka Connect, gestão de slots de replicação e um time confortável em
depurar o pipeline quando ele para. O orçamento de latência (§ ADR-09) fecha com folga
usando polling, então o ganho não paga a complexidade **hoje**.

**Caminho de migração.** A troca é invisível para o consumidor: mesmo tópico, mesmo
contrato, mesma semântica de versão. Migrar para CDC é substituir o relay, não redesenhar o
sistema. O gatilho declarado para migrar: latência P99 da etapa outbox→broker consumindo
mais de 40% do orçamento, ou volume de polling passando a pesar no banco do Portal.

**Custo aceito.** Tabela de outbox cresce e exige poda (particionamento por data, expurgo
de publicados com mais de 7 dias). O relay é um ponto de falha adicional — mitigado por
múltiplas réplicas com `SKIP LOCKED` e alarme de *lag* de outbox (idade da linha não
publicada mais antiga), que é o sinal mais importante de saúde do sistema.

---

## ADR-02 — Ordenação: versão monotônica do agregado, não relógio

**Contexto.** Eventos chegam fora de ordem por retentativa, rebalance de partição e redrive
de DLQ [II]. É preciso um critério para decidir qual evento representa o estado mais
recente.

**Opções.**

- **Last-write-wins por timestamp.** Rejeitado. Depende de relógios sincronizados entre
  máquinas; sob *clock skew*, um evento antigo com relógio adiantado sobrescreve um evento
  novo, e a corrupção é silenciosa e indetectável depois do fato.
- **Vector clocks / CRDT.** Rejeitado por desproporção. Resolvem escrita concorrente em
  múltiplos nós; aqui há um único escritor (o Portal), então a ordem total já existe na
  origem — basta transportá-la.
- **Contador monotônico por agregado.** **Escolhido.** O Portal incrementa
  `aggregate_version` do entregador na mesma transação da mudança. A versão é a ordem
  canônica, e ela viaja com o evento.

**Decisão.** O consumidor aplica um evento **se e somente se**
`evento.aggregate_version > projecao.aggregate_version` [RF-04]. Evento com versão menor ou
igual é descartado com métrica — não é erro, não é retentado.

**Efeito colateral valioso.** Essa única regra resolve **três** problemas de uma vez:
ordenação (versão menor perde), idempotência de estado (reaplicar o mesmo evento tem versão
igual, logo é descartado) e detecção de lacuna (versão saltando de 7 para 9 indica evento
perdido, o que dispara reconciliação daquele entregador).

**Custo aceito.** O evento precisa ser *fato completo*, não delta — cada evento carrega o
estado inteiro relevante do entregador. Payload maior em troca de aplicação sem ordem.
Deltas exigiriam ordem estrita, que é exatamente o que se quer evitar.

---

## ADR-03 — Locking: otimista, com particionamento removendo a disputa

**Contexto.** Duas atualizações simultâneas do mesmo entregador não podem produzir estado
inválido nem perda de escrita [CS-04].

**Decisão em duas camadas.**

1. **Particionamento por `driver_id` no broker.** Todos os eventos de um entregador caem na
   mesma partição, e uma partição é consumida por um único membro do grupo. Isso elimina a
   disputa *no caminho quente* por construção, em vez de resolvê-la por lock.
2. **Locking otimista como rede de segurança.** A escrita é uma atualização condicional:

   ```sql
   UPDATE drivers SET ..., aggregate_version = :v
   WHERE id = :id AND aggregate_version < :v
   ```

   Zero linhas afetadas significa que outra escrita já avançou a versão — o evento é
   descartado, não retentado. A condição está no `WHERE`, então a decisão é do banco, não
   de um `if` da aplicação (que teria a janela de corrida clássica entre leitura e escrita).

**Por que não pessimista.** `SELECT ... FOR UPDATE` serializa corretamente, mas mantém lock
durante a transação inteira. Com reconciliação varrendo a base em paralelo ao consumo ao
vivo, isso vira contenção e risco de deadlock sob carga de pico — exatamente quando não se
pode falhar. O caminho pessimista fica reservado a operações multi-agregado, que este
motor não tem.

**Custo aceito.** Particionar por `driver_id` cria risco de partição quente se um entregador
tiver volume anômalo de eventos. Aceitável: o volume por entregador é naturalmente baixo
(mudanças cadastrais, não telemetria). Monitorado por métrica de *lag* por partição.

---

## ADR-04 — Deduplicação: dois mecanismos, dois propósitos

**Contexto.** *At-least-once* garante duplicata [I]. A guarda de versão do ADR-02 já torna a
**aplicação de estado** idempotente. Ela **não** cobre efeito colateral externo: se o
consumo dispara uma notificação ao entregador e a mensagem é reentregue após o commit da
notificação mas antes do commit do offset, a notificação sai duas vezes.

**Decisão.**

| Mecanismo | Protege | Escopo |
|---|---|---|
| Guarda de versão (`WHERE aggregate_version < :v`) | estado da projeção | permanente, sem custo de armazenamento |
| Tabela de deduplicação por `event_id` | efeitos colaterais externos | TTL de 7 dias, alinhado à retenção do broker |

A barreira de dedup é gravada **na mesma transação** que a mudança de estado. O efeito
colateral externo é despachado depois, a partir do estado persistido — nunca de dentro do
handler do evento.

**Custo aceito.** A tabela de dedup é escrita a cada evento; é uma inserção por evento com
índice único em `event_id`. Podada por TTL. Se a reentrega ocorrer após a expiração do TTL,
a duplicata de efeito colateral volta a ser possível — risco aceito, pois exigiria uma
reentrega com mais de 7 dias de atraso, cenário em que a reconciliação já teria agido.

---

## ADR-05 — Mensageria: log particionado com grupos de consumo

**Contexto.** O fan-out precisa suportar N consumidores sem que o Portal os conheça [III] e
sem que um consumidor lento afete outro [RNF-05].

| Opção | Fan-out | Replay | Ordem por chave | Custo |
|---|---|---|---|---|
| Log particionado (Kafka) | grupos de consumo independentes | **sim**, por retenção | sim | plataforma dedicada |
| SNS → SQS por consumidor | sim, uma fila por consumidor | não (mensagem some ao consumir) | só com FIFO, limitando vazão | baixo, gerenciado |
| RabbitMQ com exchange fanout | sim | não | limitada | médio |
| Fila nativa Rails (Solid Queue/Sidekiq) | não naturalmente | não | não | mínimo |

**Decisão.** Log particionado, tópico único `drivers.lifecycle.v1`, particionado por
`driver_id`, um **consumer group por plataforma consumidora**.

**O critério que decidiu.** Não foi vazão — foi **replay**. Um log retido permite que um
consumidor volte no tempo e reprocesse a partir de um offset. Isso é a espinha dorsal da
recuperação de desastre (§ ADR-08) e é impossível em fila com consumo destrutivo. Com SQS,
qualquer bug de consumo que corrompa a projeção só se corrige via reconciliação completa
contra o Portal; com log, corrige-se relendo o próprio log, sem tocar no system of record.

**Custo aceito.** Kafka é infraestrutura pesada para um time Rails. A decisão só se sustenta
porque a premissa é de mensageria operada como plataforma compartilhada do ecossistema. Se
essa premissa cair, a alternativa é SNS→SQS aceitando a perda de replay e compensando com
reconciliação mais frequente — decisão que deve ser reaberta, não contornada.

**Retenção definida em 7 dias**, e não nos 24h padrão: precisa cobrir com folga o cenário de
outage de 2h da Black Friday mais o tempo de diagnóstico humano em fim de semana.

---

## ADR-06 — Elegibilidade na borda, com fato completo no evento

**Contexto.** A Ultra-rápida tem critérios mais restritivos que o Portal — por exemplo,
recusa pessoa física [C4].

**Decisão.** O Portal emite fatos cadastrais crus (`legal_entity_type`, `documents_status`,
`vehicle`, `service_radius_km`). Cada consumidor avalia elegibilidade localmente [V].

**Consequência de design que decorre disso.** O evento precisa carregar **todos os fatos que
qualquer consumidor plausível possa precisar** para decidir. Se o payload trouxesse apenas
`status: approved`, a Ultra-rápida teria que consultar o Portal a cada evento para descobrir
a natureza jurídica — reintroduzindo acoplamento síncrono e derrubando o SLA. O evento
autocontido é o que mantém o fan-out barato.

**Custo aceito.** A regra de elegibilidade fica distribuída, sem ponto único de auditoria.
Mitigado por [RF-06]: todo veredito é persistido com motivo e versão de origem, tornando
auditável a pergunta "por que este entregador não recebeu oferta às 14h32?".

---

## ADR-07 — Resiliência: retentativa onde a falha acontece

**Contexto.** Duas classes de falha distintas, frequentemente confundidas.

| Classe | Falha | Onde é resolvida |
|---|---|---|
| A | Portal gravou o estado mas não publicou (broker fora, rede) | **outbox**: a linha permanece não publicada, o relay retenta indefinidamente com backoff |
| B | Evento publicado, consumidor falha ao processar | **consumidor**: retentativa do broker → DLQ do próprio consumidor |

**Decisão.** Nunca há reenvio solicitado ao produtor. Um consumidor doente não pede nada ao
Portal [III] — se pedisse, o Portal precisaria conhecer os consumidores e sua saúde, e um
consumidor degradado passaria a degradar todos os outros pelo produtor compartilhado.

**Política declarada** [VI]:

- Timeout: 2s de conexão, 5s de leitura, separados.
- Retentativa: exponential backoff com **full jitter**, base 500ms, teto 30s, 5 tentativas.
  Full jitter (`sleep = random(0, min(cap, base * 2^n))`) e não jitter parcial: sob
  recuperação de outage, milhares de consumidores retentando em backoff sem jitter
  sincronizam e recriam o pico que derrubou o sistema.
- Circuit breaker no cliente HTTP do consumidor: abre com 50% de falha em janela de 20
  chamadas, half-open após 30s com uma sonda.
- Destino final: DLQ com o motivo e o payload originais preservados; redrive é operação
  manual e deliberada, nunca automática.

**Ponto sutil — quando o broker volta.** Se o broker esteve fora por 2h, o relay tem 2h de
eventos acumulados no outbox e vai despejá-los o mais rápido que conseguir. Aqui **jitter
não ajuda**: não é rebanho de muitos clientes, é um único relay a plena carga. A defesa é
outra — **limitador de vazão na saída do relay**, dimensionado para não ultrapassar a
capacidade de consumo agregada. Jitter resolve dessincronização; teto de vazão resolve
volume. São problemas diferentes e exigem mecanismos diferentes.

---

## ADR-08 — Recuperação de desastre: três topologias, uma máquina de estados

**Contexto.** "Indisponibilidade total dos serviços por 2 horas durante a Black Friday" não
é um cenário — são três, com recuperações diferentes.

| Topologia | O que se perde | Recuperação |
|---|---|---|
| **T1 — consumidor fora** | nada; broker retém | retomada por offset (*checkpoint*) |
| **T2 — broker fora** | nada; outbox retém | despejo do outbox sob vazão limitada (ADR-07) |
| **T3 — Portal fora** | nenhum evento (não houve escrita) | reconciliação detecta divergência residual |

**T1 é o cenário principal** do desenho, por ser o mais provável e o único que exige
máquina de estados própria:

```
outage → fail-closed em ativações → retomada por checkpoint
       → aplicação com dedup + guarda de versão
       → fila de reconciliação (concorrência fixa + vazão limitada + cursor)
       → estado consistente
```

**Fail-closed e sua assimetria.** Durante a indisponibilidade, entregador criado ou ativado
não é elegível — ausência de dado significa negar, o que é seguro. Mas o **inverso não é
simétrico**: um bloqueio de segurança emitido durante a janela não pode ser "fail-closed"
porque o consumidor não sabe que ele existe. Manter o último estado conhecido significaria
manter ativo alguém que foi bloqueado.

A defesa é [VII]: **TTL de frescor**. Se `now - last_synced_at > FRESHNESS_TTL`, o entregador
sai do pool independentemente do status gravado. Inverte-se o ônus da prova: em vez de
"confio no último estado até saber o contrário", passa a valer "o estado precisa estar
recente para valer". `FRESHNESS_TTL` = 15 minutos, com *heartbeat* periódico por entregador
ativo garantindo renovação mesmo sem mudança cadastral.

**A armadilha da reconciliação.** A fila de reconciliação lê estado do Portal e o aplica —
e é aqui que o mecanismo de reparo pode virar o mecanismo de corrupção. Se o entregador X é
lido às 14:00, a fila engasga, e a aplicação só ocorre às 14:08, um evento legítimo de
14:03 já aplicado seria sobrescrito por dado de 14:00.

A defesa é que **a reconciliação não é um caminho privilegiado**: ela passa pela mesma
guarda de versão do consumo ao vivo. Isso impõe um requisito duro à API [RF-10]: o endpoint
de reconciliação **precisa devolver `aggregate_version` junto com o estado**. Um endpoint
que devolvesse apenas o estado tornaria o guardrail inexistente e a corrupção invisível.

**Vazão da reconciliação.** Cursor estável `(updated_at, id)` — nunca `OFFSET`, que sob
escrita concorrente pula e repete linhas. Páginas de 500 registros, concorrência fixa de 4
workers, teto de 500 entregadores/s. A 500/s, 300.000 entregadores levam **10 minutos** — o
gargalo dimensionado é o banco do Portal, não o consumidor. Os três parâmetros são
ajustáveis em runtime para que a operação possa afrouxar ou apertar durante um incidente
sem deploy.

---

## ADR-09 — Orçamento de latência do SLA de 30s

O SLA P99 é tratado como **orçamento distribuído**, não como meta agregada — sem fatiar,
uma violação não é atribuível a nenhum componente [IX].

| Etapa | Orçamento P99 | Como se mede |
|---|---|---|
| Commit no Portal → linha visível no outbox | 100 ms | dentro da transação |
| Espera do polling do relay | 1.000 ms | intervalo de polling |
| Publicação no broker (com retentativa) | 500 ms | latência do produtor |
| Permanência no broker até o consumo | 2.000 ms | *consumer lag* |
| Processamento e aplicação no consumidor | 1.400 ms | duração do handler |
| **Total do caminho feliz** | **≈ 5 s** | |
| **Folga para degradação** | **25 s** | absorve retentativa e pico |

A folga é deliberada e generosa: o P99 se rompe em degradação, não em regime normal.
Perder 83% do orçamento e ainda cumprir o SLA é o que torna a retentativa com backoff
viável dentro dos 30s. Um alarme dispara quando o caminho feliz passa de 10s — muito antes
do SLA ser violado, o que dá margem de ação humana.

---

## ADR-10 — Acesso a dados no Rails: N+1 como falha de build

**Contexto.** O ecossistema Rails torna N+1 fácil de introduzir e difícil de ver em revisão
— e agentes de IA são especialmente propensos a escrever `drivers.each { |d| d.profile }`.

**Decisão.**

- Consumo em lote: eventos são processados em lotes por partição, com `upsert_all` numa
  única ida ao banco, em vez de N `save!`.
- Reconciliação com `find_each` em cursor, nunca `all.each` (que carrega a base em memória).
- Associações declaradas com `includes` explícito em todo caminho quente.
- **`prosopite` em modo `raise` no ambiente de teste**: uma consulta N+1 detectada quebra a
  suíte. Isso move a detecção de "code review atento" para "CI determinístico", que é o
  único regime que funciona quando o autor do código é um agente.

**Custo aceito.** Falsos positivos do detector em consultas legitimamente repetidas exigem
supressão explícita e comentada — o que é aceitável, pois torna a exceção visível na revisão.

---

## ADR-11 — Segurança: o canal não é evidência de autenticidade

**Contexto.** O desafio pede que a arquitetura se mantenha segura a ataques. A superfície
real de um motor de sincronização não é a API pública — é o **canal de eventos**, porque
quem consegue produzir nele consegue ativar entregadores.

**Modelo de ameaça e controles.**

| Ameaça | Controle |
|---|---|
| Ator produz evento forjado no tópico | ACL de produção restrita ao Portal + **evento assinado (JWS)**; o consumidor valida a assinatura, não o remetente do canal [VIII] |
| Credencial de consumidor vazada | credencial por consumidor via SASL/SCRAM, somente leitura, rotacionável e revogável isoladamente |
| Interceptação em trânsito | mTLS entre serviços e para o broker |
| Replay de evento antigo capturado | guarda de versão descarta por construção (ADR-02); assinatura cobre `event_id` e `occurred_at` |
| Vazamento de PII pelo evento | payload sem CPF/CNH/dados bancários; apenas referência resolvível sob autorização, com criptografia em nível de campo e retenção mínima (LGPD) [RNF-06] |
| Abuso da API de reconciliação | OAuth2 client credentials com escopo por consumidor, *rate limit* por cliente, e paginação obrigatória impedindo varredura irrestrita |
| Escalada por dependência comprometida | `bundler-audit` e verificação de licenças como *gate* de CI |

**O ponto que sustenta o resto.** Assinatura na origem é o que permite que a segurança
**não dependa da configuração correta do broker**. Se uma ACL for afrouxada por engano — e
ACLs são afrouxadas por engano — o consumidor continua rejeitando o evento forjado. Defesa
em profundidade significa que o erro de configuração mais provável não é suficiente para
comprometer o sistema.
