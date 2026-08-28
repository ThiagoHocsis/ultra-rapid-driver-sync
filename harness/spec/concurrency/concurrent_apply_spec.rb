# frozen_string_literal: true

require 'rails_helper'

# Testes de CONCORRÊNCIA com threads reais.
#
# O detalhe que faz este arquivo existir: a suíte padrão do Rails envolve cada exemplo numa
# transação e faz rollback ao final. Threads abrem **conexões próprias**, e uma conexão não
# enxerga a transação não commitada de outra. Rodar teste de concorrência com
# `use_transactional_tests = true` produz um teste que passa sem exercitar nada — o pior
# tipo de teste, porque dá confiança falsa exatamente na garantia mais difícil.
#
# Por isso, aqui: transactional tests desligado e limpeza por truncação.
#
# Isto também é um guardrail contra agente de IA: um agente que "conserte" um teste
# instável de concorrência religando as transações transacionais transformaria a suíte num
# no-op verde. A trava está no `before` abaixo, e o CI falha se ela for removida.

RSpec.describe 'aplicação concorrente de eventos', :concurrency do
  self.use_transactional_tests = false

  let(:driver_id)   { SecureRandom.uuid }
  let(:thread_count) { 16 }

  before do
    DatabaseCleaner.strategy = :truncation
    DatabaseCleaner.clean

    raise 'teste de concorrência exige transactional_tests desligado' if
      self.class.use_transactional_tests

    Sync::DriverProjection.create!(driver_id: driver_id, aggregate_version: 0,
                                   status: 'pending', legal_entity_type: 'company',
                                   documents_status: 'pending', last_synced_at: Time.current)
  end

  after { DatabaseCleaner.clean }

  # Solta todas as threads no mesmo instante. Sem a barreira, elas partem escalonadas
  # pelo custo de criação e a janela de corrida praticamente não se abre — o teste
  # passaria sem nunca ter havido concorrência real.
  def run_in_parallel(count)
    barrier = Concurrent::CyclicBarrier.new(count)
    errors  = Concurrent::Array.new

    threads = Array.new(count) do |i|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier.wait
          yield(i)
        rescue StandardError => e
          errors << e
        end
      end
    end

    threads.each(&:join)
    errors
  end

  # ---------------------------------------------------------------------------
  # ADR-03 — Locking otimista, guarda no WHERE
  # ---------------------------------------------------------------------------
  it 'converge para a maior versão sob escrita simultânea, sem perda de atualização' do
    events = (1..thread_count).map do |version|
      build(:driver_event, driver_id: driver_id, aggregate_version: version,
            status: version.even? ? 'active' : 'inactive')
    end

    errors = run_in_parallel(thread_count) { |i| Sync::EventApplier.apply(events[i]) }

    expect(errors).to be_empty
    projection = Sync::DriverProjection.find_by(driver_id: driver_id)

    # A maior versão vence independentemente de qual thread chegou por último.
    expect(projection.aggregate_version).to eq(thread_count)
    expect(projection.status).to eq('active')
  end

  it 'não produz estado misturado entre dois eventos concorrentes' do
    # Falha clássica de leitura-modificação-escrita: o estado final tem o status de um
    # evento e o perfil de outro. Cada campo isolado parece plausível; o conjunto é um
    # estado que nunca existiu no Portal, e nenhum teste de campo único o detecta.
    moto = build(:driver_event, driver_id: driver_id, aggregate_version: 20,
                 status: 'active').deep_merge(
                   'data' => { 'vehicle_type' => 'motorcycle', 'service_radius_km' => 10 }
                 )
    car = build(:driver_event, driver_id: driver_id, aggregate_version: 21,
                status: 'blocked').deep_merge(
                  'data' => { 'vehicle_type' => 'car', 'service_radius_km' => 30 }
                )

    50.times do
      Sync::DriverProjection.where(driver_id: driver_id).update_all(aggregate_version: 0)

      run_in_parallel(2) { |i| Sync::EventApplier.apply(i.zero? ? moto : car) }

      projection = Sync::DriverProjection.find_by(driver_id: driver_id)
      coherent = [
        { status: 'active',  vehicle_type: 'motorcycle', service_radius_km: 10 },
        { status: 'blocked', vehicle_type: 'car',        service_radius_km: 30 }
      ]

      expect(coherent).to include(
        status: projection.status,
        vehicle_type: projection.vehicle_type,
        service_radius_km: projection.service_radius_km
      ), "estado misturado: #{projection.attributes.slice('status', 'vehicle_type', 'service_radius_km')}"
    end
  end

  # ---------------------------------------------------------------------------
  # Princípio I — barreira de deduplicação sob concorrência
  # ---------------------------------------------------------------------------
  it 'dispara efeito colateral uma única vez quando o mesmo evento chega em paralelo' do
    # Rebalance de partição reentrega a mesma mensagem a dois consumidores ao mesmo
    # tempo. Dedup por "SELECT depois INSERT" na aplicação tem janela de corrida:
    # a garantia precisa vir do índice único, dentro da mesma transação da projeção.
    event = build(:driver_event, driver_id: driver_id, aggregate_version: 30)
    notifications = Concurrent::AtomicFixnum.new(0)

    allow(Sync::DispatchPoolNotifier).to receive(:driver_state_changed) { notifications.increment }

    errors = run_in_parallel(thread_count) { Sync::EventApplier.apply(event) }

    expect(errors).to be_empty, "corrida na dedup vazou exceção: #{errors.map(&:message).uniq}"
    expect(notifications.value).to eq(1)
    expect(Sync::ProcessedEvent.where(event_id: event['event_id']).count).to eq(1)
  end

  # ---------------------------------------------------------------------------
  # ADR-08 — reconciliação concorrente com consumo ao vivo
  # ---------------------------------------------------------------------------
  it 'reconciliação em paralelo com consumo ao vivo nunca regride a versão' do
    # É o cenário real do catch-up pós-outage: a varredura de reconciliação roda
    # enquanto o consumidor drena o backlog do broker. Os dois escrevem no mesmo
    # registro ao mesmo tempo.
    live_events = (40..55).map do |v|
      build(:driver_event, driver_id: driver_id, aggregate_version: v, status: 'active')
    end
    snapshots = (35..50).map do |v|
      { 'driver_id' => driver_id, 'aggregate_version' => v, 'status' => 'inactive',
        'legal_entity_type' => 'company', 'documents_status' => 'approved' }
    end

    versions = Concurrent::Array.new

    errors = run_in_parallel(live_events.size + snapshots.size) do |i|
      if i < live_events.size
        Sync::EventApplier.apply(live_events[i])
      else
        Sync::ReconciliationApplier.apply(snapshots[i - live_events.size])
      end
      versions << Sync::DriverProjection.find_by(driver_id: driver_id).aggregate_version
    end

    expect(errors).to be_empty
    expect(Sync::DriverProjection.find_by(driver_id: driver_id).aggregate_version).to eq(55)
    expect(versions.max).to eq(55)
  end

  it 'não gera deadlock sob disputa sustentada' do
    # Deadlock é o custo que o locking pessimista teria trazido (ADR-03).
    # Este teste é a evidência executável de que a escolha otimista se sustenta —
    # e o alarme que dispara se alguém reintroduzir SELECT ... FOR UPDATE no caminho.
    events = (100..160).map do |v|
      build(:driver_event, driver_id: driver_id, aggregate_version: v)
    end

    errors = Timeout.timeout(30) do
      run_in_parallel(events.size) { |i| Sync::EventApplier.apply(events[i]) }
    end

    deadlocks = errors.grep(ActiveRecord::Deadlocked)
    expect(deadlocks).to be_empty, "deadlock sob concorrência: #{deadlocks.size} ocorrência(s)"
  end
end
