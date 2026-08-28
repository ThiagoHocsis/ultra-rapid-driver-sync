# Especificação — Motor de Sincronização de Entregadores

**Feature branch:** `001-driver-sync-engine`
**Status:** aprovada para planejamento
**Data:** 2026-08-27

> Este documento descreve **o que** o motor precisa garantir e **por quê**, sem decidir
> tecnologia. As escolhas de implementação — broker, estratégia de lock, mecanismo de
> publicação — são justificadas em [`research.md`](./research.md), e suas estruturas
> estão em [`data-model.md`](./data-model.md).

---

## 1. Problema

O **Portal dos Entregadores** é o system of record do ciclo de vida do entregador:
cadastro, documentação, aprovação e manutenção cadastral. A **Ultra-rápida** precisa desses
dados quase em tempo real para decidir quem pode receber oferta de corrida.

Hoje esse dado não flui. Consequências operacionais diretas:

- Um entregador aprovado no Portal não consegue trabalhar até que o dado alcance a
  Ultra-rápida — perda de oferta e de receita, e atrito com o entregador.
- Um entregador **bloqueado** no Portal continua recebendo ofertas na Ultra-rápida — risco
  operacional, reputacional e de segurança. Esta é a falha assimetricamente mais grave.
- Cada nova plataforma do ecossistema Magalu que precisar do mesmo dado tende a construir
  sua própria integração ponto a ponto com o Portal, multiplicando carga sobre o system of
  record e replicando a mesma lógica de sincronização N vezes.

A solução precisa nascer **agnóstica**: resolver a Ultra-rápida hoje sem que a chegada do
consumidor N+1 amanhã exija reescrever a arquitetura core.

## 2. Escopo

### Dentro do escopo

- Propagação das mudanças de ciclo de vida do entregador do Portal para plataformas
  consumidoras: **criação**, **ativação/inativação** e **atualização de perfil**.
- Garantias de correção sob falha: idempotência, convergência sob desordem, resiliência a
  indisponibilidade parcial e total.
- Contratos formais dos eventos e da API de reconciliação.
- Harness de testes e guardrails de CI que protegem essas garantias de regressão,
  incluindo regressão introduzida por código gerado por agentes de IA.
- Mecanismo de reconciliação e catch-up após indisponibilidade prolongada.

### Fora do escopo

- Regras internas de despacho e precificação da Ultra-rápida (consomem o resultado, não
  fazem parte do motor).
- Fluxo de onboarding, upload e aprovação de documentos dentro do Portal.
- Aplicação executável completa. A entrega é o design; código aparece apenas como
  evidência de mecanismo.

## 3. Cenários de usuário

### C1 — Entregador recém-aprovado começa a operar

Um entregador conclui o cadastro e é aprovado no Portal. **Em até 30 segundos** ele está
apto a receber ofertas na Ultra-rápida, desde que atenda também aos critérios mais
restritivos dela.

### C2 — Bloqueio de segurança

O time de risco inativa um entregador no Portal. **Em até 30 segundos** ele deixa de
receber ofertas. Se o evento não chegar por qualquer motivo, o entregador **ainda assim**
deve sair do pool de despacho ao expirar o prazo de frescor do seu registro — a ausência de
informação nunca pode ser interpretada como permissão.

### C3 — Troca de veículo

Um entregador troca de moto para carro, alterando raio e tipo de entrega elegível. A
mudança reflete na Ultra-rápida dentro do SLA, e ofertas já em andamento não são corrompidas
por aplicação parcial da atualização.

### C4 — Elegibilidade divergente

Um entregador pessoa física é aprovado no Portal e passa a operar em outras plataformas do
ecossistema. Na Ultra-rápida, que exige pessoa jurídica, ele **não** se torna elegível. A
recusa é registrada com o motivo e a versão do dado que a originou, e não gera erro nem
retentativa: é decisão de negócio, não falha técnica.

### C5 — Eventos fora de ordem

O Portal emite, em sequência, `ativado` e depois `bloqueado` para o mesmo entregador. Por
retentativa, os eventos chegam invertidos à Ultra-rápida. O estado final deve ser
**bloqueado** — o estado emitido por último, não o recebido por último.

### C6 — Nova plataforma consumidora

Uma segunda plataforma do ecossistema passa a consumir o mesmo fluxo. Isso não exige
mudança de código, de schema ou de configuração no Portal, e não altera a latência nem a
carga percebida pelos consumidores já existentes.

### C7 — Indisponibilidade prolongada em pico

Durante a Black Friday, os serviços ficam indisponíveis por 2 horas. Nenhuma mudança
emitida pelo Portal nesse período é perdida. Ao retornar, o sistema converge para o estado
correto sem sobrecarregar o banco do Portal, e nenhum entregador ativado durante a janela
de indisponibilidade opera antes de ter seu estado confirmado.

## 4. Requisitos funcionais

| ID | Requisito |
|---|---|
| **RF-01** | O Portal emite um evento para toda mudança de estado do entregador que altere criação, status ou perfil. |
| **RF-02** | Nenhuma mudança de estado persistida no Portal pode existir sem o evento correspondente, e vice-versa: as duas escritas são atômicas. |
| **RF-03** | Todo evento carrega identificador único imutável, versão monotônica do agregado, instante de emissão e identificador de correlação. |
| **RF-04** | O consumidor aplica um evento apenas se sua versão for superior à versão já persistida para aquele entregador. |
| **RF-05** | Reprocessar qualquer evento, quantas vezes for, não altera o estado final nem duplica efeitos colaterais. |
| **RF-06** | O consumidor avalia elegibilidade com seus próprios critérios, mais restritivos que os do Portal, e registra o motivo de toda recusa. |
| **RF-07** | Todo registro de entregador no consumidor tem instante da última sincronização confirmada. |
| **RF-08** | Entregador cujo estado não é confirmado há mais que o prazo de frescor é excluído do pool de despacho, independentemente do status persistido. |
| **RF-09** | Falha de processamento no consumidor é retentada com backoff e jitter e, esgotado o teto, direcionada a uma fila de mensagens mortas com o motivo preservado. |
| **RF-10** | O Portal expõe uma interface de reconciliação que permite a um consumidor varrer a base por página, a partir de um marcador temporal, recebendo o estado **acompanhado da versão do agregado**. |
| **RF-11** | A reconciliação usa a mesma regra de comparação por versão que o consumo de eventos: um estado lido da reconciliação nunca sobrescreve um evento mais recente já aplicado. |
| **RF-12** | A varredura de reconciliação opera sob vazão limitada e concorrência fixa, configuráveis em tempo de execução. |
| **RF-13** | Adicionar um consumidor não requer alteração de código, schema ou configuração no Portal. |
| **RF-14** | O consumidor rejeita evento cuja autenticidade não possa ser verificada criptograficamente. |
| **RF-15** | Toda decisão de descarte — versão obsoleta, duplicata, assinatura inválida, inelegibilidade — emite métrica identificando o motivo. |

## 5. Requisitos não funcionais

| ID | Requisito | Alvo |
|---|---|---|
| **RNF-01** | Latência de sincronização ponta a ponta | ≤ 30s no P99 |
| **RNF-02** | Base de entregadores ativos suportada | ~300.000 |
| **RNF-03** | Durabilidade do evento após commit no Portal | perda zero |
| **RNF-04** | Reconciliação completa da base após outage | sem violar o orçamento de carga do banco do Portal |
| **RNF-05** | Acréscimo de latência por consumidor adicional | nulo (consumidores independentes) |
| **RNF-06** | Dados pessoais sensíveis em payload de evento | ausentes; acesso por referência autorizada |
| **RNF-07** | Atribuição de violação de SLA | rastreável por etapa do caminho |

## 6. Entidades de domínio

- **Entregador (Driver)** — agregado raiz. Identidade estável no ecossistema, estado de
  ciclo de vida, natureza jurídica (PF/PJ), perfil operacional e versão monotônica.
- **Perfil operacional** — veículo, raio de atendimento, modalidades habilitadas (goods,
  food). Determina que tipo de oferta o entregador pode receber.
- **Evento de ciclo de vida** — fato imutável emitido pelo Portal: criação, atualização de
  perfil ou mudança de status.
- **Projeção local do entregador** — cópia do estado mantida por cada consumidor, com sua
  própria versão aplicada, instante de última sincronização e veredito de elegibilidade.
- **Veredito de elegibilidade** — decisão do consumidor sobre se o entregador pode operar
  nele, com motivo e versão do agregado que a originou.

## 7. Critérios de sucesso

| ID | Critério | Verificação |
|---|---|---|
| **CS-01** | Mudança no Portal reflete no consumidor em ≤ 30s no P99 | histograma de `applied_at − occurred_at` em produção |
| **CS-02** | Qualquer permutação de uma sequência de eventos converge para o mesmo estado | teste de propriedade no CI |
| **CS-03** | Aplicar o mesmo evento N vezes equivale a aplicá-lo uma vez | teste de propriedade no CI |
| **CS-04** | Atualizações concorrentes do mesmo entregador não produzem estado inválido nem perda de escrita | teste de concorrência com threads reais no CI |
| **CS-05** | Entregador com estado obsoleto não recebe oferta | teste de expiração de frescor no CI |
| **CS-06** | Consumidor N+1 é adicionado sem alteração no Portal | fitness function de arquitetura no CI |
| **CS-07** | Nenhum evento é perdido em outage de 2h | teste de integração com broker e consumidor derrubados |
| **CS-08** | Reconciliação não sobrescreve estado mais novo | teste de propriedade cruzando snapshot antigo com evento recente |

## 8. Premissas

- O Portal é a única fonte de verdade do cadastro; consumidores nunca escrevem de volta.
- O Portal consegue atribuir versão monotônica por entregador dentro da transação de
  escrita.
- Consumidores toleram consistência eventual dentro da janela do SLA; nenhum fluxo exige
  leitura estritamente consistente do Portal em caminho quente.
- A infraestrutura de mensageria é operada como plataforma compartilhada do ecossistema,
  não provisionada por time.

## 9. Fora de decisão nesta fase

Deliberadamente não decidido aqui, e resolvido em [`research.md`](./research.md):

- Tecnologia de mensageria e topologia de tópicos.
- Mecanismo de publicação (polling do outbox vs. captura de log de transações).
- Estratégia de lock no consumidor.
- Valor concreto do prazo de frescor e das cotas de vazão da reconciliação.
