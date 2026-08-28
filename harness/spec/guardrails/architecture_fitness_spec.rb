# frozen_string_literal: true

require 'rails_helper'

# FITNESS FUNCTIONS — testes sobre o código, não sobre o comportamento.
#
# Todos os testes anteriores verificam que o sistema *faz a coisa certa*. Estes verificam
# que ele *continua construído do jeito certo* — a classe de regressão que passa despercebida
# porque nenhum teste de comportamento quebra.
#
# É a categoria mais importante do harness quando o autor do código é um agente de IA.
# Um agente otimiza para "os testes passam". Ele resolve um `NoMethodError` adicionando um
# require, resolve um teste instável de concorrência religando as transações transacionais,
# e resolve uma regra de negócio faltante importando o módulo do consumidor dentro do núcleo.
# Cada uma dessas "soluções" deixa a suíte verde e destrói uma garantia arquitetural.
#
# Estes testes tornam essas saídas indisponíveis.

RSpec.describe 'fitness functions da arquitetura' do
  CORE = Rails.root.join('app/domain/sync')

  def core_sources
    Dir.glob(CORE.join('**/*.rb'))
  end

  # ---------------------------------------------------------------------------
  # Princípio III — núcleo agnóstico de consumidor
  # ---------------------------------------------------------------------------
  describe 'núcleo agnóstico de consumidor' do
    CONSUMER_TOKENS = %w[UltraFast Ultrafast ultra_rapida ultra_fast Food Goods].freeze

    it 'não referencia nenhum consumidor específico' do
      offenders = core_sources.select do |file|
        source = File.read(file)
        CONSUMER_TOKENS.any? { |token| source.match?(/\b#{Regexp.escape(token)}\b/) }
      end

      expect(offenders).to be_empty, <<~MSG
        O núcleo de sincronização referencia um consumidor específico:
        #{offenders.join("\n")}

        O Portal publica fatos; quem decide o que fazer com eles é a borda (Princípio V).
        Acoplar o núcleo a um consumidor quebra o fan-out sem gargalo (Princípio III) e
        transforma "adicionar o consumidor N+1" em mudança no system of record.
      MSG
    end

    it 'não faz chamada síncrona a consumidor' do
      # A saúde de um consumidor jamais pode se propagar de volta ao produtor.
      offenders = core_sources.select do |file|
        File.read(file).match?(/(Net::HTTP|Faraday|HTTParty|RestClient)/)
      end

      expect(offenders).to be_empty,
                           "chamada HTTP síncrona no núcleo: #{offenders.join(', ')}"
    end
  end

  # ---------------------------------------------------------------------------
  # ADR-03 — a guarda de versão vive no SQL, não num if
  # ---------------------------------------------------------------------------
  describe 'guarda de versão' do
    it 'aplica a projeção com condição de versão no WHERE' do
      # Regressão específica e altamente provável: um agente reescreve o UPDATE
      # condicional como leitura, comparação em Ruby e escrita. Fica mais legível,
      # passa em todos os testes de unidade — e reintroduz a corrida clássica entre
      # a leitura e a escrita, que só aparece sob concorrência real em produção.
      source = File.read(CORE.join('event_applier.rb'))

      expect(source).to match(/aggregate_version\s*<\s*[:?]/),
                        'a guarda de versão não está no WHERE do UPDATE'
      expect(source).not_to match(/if\s+.*aggregate_version\s*[<>]=?\s*.*\n\s*.*update/i),
                            'comparação de versão em Ruby antes do update: janela de corrida'
    end

    it 'não usa lock pessimista no caminho quente' do
      offenders = core_sources.select { |f| File.read(f).match?(/lock!|FOR UPDATE|with_lock/) }

      expect(offenders).to be_empty, <<~MSG
        Lock pessimista no caminho de consumo: #{offenders.join(', ')}

        ADR-03 escolheu locking otimista deliberadamente. Lock pessimista com a
        reconciliação varrendo a base em paralelo gera contenção e deadlock sob pico —
        exatamente quando não se pode falhar.
      MSG
    end
  end

  # ---------------------------------------------------------------------------
  # Princípio VI — nenhum default implícito
  # ---------------------------------------------------------------------------
  describe 'políticas de degradação declaradas' do
    it 'todo cliente externo declara timeout, retentativa e circuit breaker' do
      undeclared = Sync::ExternalClients.registry.reject do |client|
        client.timeout.present? && client.retry_policy.present? && client.circuit_breaker.present?
      end

      expect(undeclared).to be_empty,
                            "cliente sem política declarada: #{undeclared.map(&:name).join(', ')}"
    end

    it 'usa full jitter na retentativa, não backoff puro' do
      # Backoff sem jitter sincroniza os clientes que falharam juntos e recria,
      # na recuperação, o pico que derrubou o sistema.
      Sync::ExternalClients.registry.each do |client|
        expect(client.retry_policy.jitter).to eq(:full),
                                              "#{client.name} retenta sem full jitter"
      end
    end

    it 'o relay do outbox tem teto de vazão na saída' do
      # Jitter resolve dessincronização de muitos clientes. Não resolve um único relay
      # despejando 2h de backlog a plena carga quando o broker volta (ADR-07).
      expect(Sync::OutboxRelay.throughput_limit).to be_present
      expect(Sync::OutboxRelay.throughput_limit).to be < Sync::Consumers.aggregate_capacity
    end
  end

  # ---------------------------------------------------------------------------
  # ADR-10 — N+1 como falha de build
  # ---------------------------------------------------------------------------
  describe 'acesso a dados' do
    it 'não introduz N+1 no caminho de consumo em lote', :prosopite do
      # Prosopite em modo raise: a detecção sai da revisão humana atenta e entra no CI
      # determinístico — o único regime que funciona quando o autor é um agente.
      events = 200.times.map { |i| build(:driver_event, aggregate_version: i + 1) }

      expect { Sync::BatchConsumer.process(events) }.not_to raise_error
    end

    it 'a varredura de reconciliação usa cursor estável, nunca OFFSET' do
      # OFFSET sob escrita concorrente pula e repete linhas — numa reconciliação,
      # "pular" significa deixar um entregador bloqueado ativo.
      source = File.read(CORE.join('reconciliation_scanner.rb'))

      expect(source).not_to match(/\.offset\(/), 'OFFSET na varredura de reconciliação'
      expect(source).to match(/updated_at.*id|find_each|in_batches/m)
    end
  end

  # ---------------------------------------------------------------------------
  # Meta-guardrails: proteger o próprio harness
  # ---------------------------------------------------------------------------
  describe 'integridade do harness' do
    it 'nenhum teste do núcleo está pendente, pulado ou filtrado' do
      # A saída mais barata para um agente diante de um teste difícil é desativá-lo.
      offenders = Dir.glob(Rails.root.join('harness/spec/**/*_spec.rb')).select do |file|
        File.read(file).match?(/^\s*(x(it|describe|context)|skip|pending)\b/)
      end

      expect(offenders).to be_empty,
                           "teste desativado no harness: #{offenders.join(', ')}"
    end

    it 'os testes de concorrência não rodam sob transação transacional' do
      # Religar transactional_tests faria a suíte de concorrência passar sem
      # exercitar nada: threads têm conexões próprias e não enxergam a transação
      # não commitada uma da outra.
      source = File.read(Rails.root.join('harness/spec/concurrency/concurrent_apply_spec.rb'))

      expect(source).to match(/use_transactional_tests\s*=\s*false/)
    end

    it 'todo princípio da constituição tem teste correspondente' do
      # Governança executável: um princípio sem mecanismo é considerado violado.
      principles = Sync::Constitution.principles          # extraídos do markdown
      covered    = Sync::Constitution.principles_with_tests # varre as tags dos specs

      expect(principles - covered).to be_empty,
                                      "princípio sem teste: #{(principles - covered).join(', ')}"
    end
  end
end
