# frozen_string_literal: true

require 'rails_helper'
require 'rantly/rspec_extensions'

# Testes de PROPRIEDADE das invariantes centrais do motor.
#
# Por que propriedade e não exemplo:
#
# Um teste de exemplo afirma "para esta entrada, este resultado". Um agente de IA
# encarregado de "fazer o teste passar" pode satisfazê-lo especializando o código para os
# casos escolhidos — e o teste fica verde sobre uma implementação errada.
#
# Um teste de propriedade afirma "para TODA entrada gerada, esta relação se mantém". Não há
# como satisfazê-lo por especialização: só implementando a regra. É por isso que as três
# invariantes que o desafio nomeia — idempotência, ordem e concorrência — são verificadas
# aqui por propriedade, e não por cenário escolhido a dedo.
#
# Ao falhar, Rantly reduz (`shrink`) o contraexemplo ao menor caso que ainda quebra,
# entregando um caso de regressão mínimo em vez de um dump de 40 eventos aleatórios.

RSpec.describe Sync::EventApplier, :aggregate_failures do
  let(:driver_id) { SecureRandom.uuid }

  # ---------------------------------------------------------------------------
  # Princípio I — Idempotência estrita
  # ---------------------------------------------------------------------------
  describe 'idempotência' do
    it 'aplicar o mesmo evento N vezes equivale a aplicá-lo uma vez' do
      property_of do
        Rantly { [range(1, 50), range(2, 10)] }
      end.check do |(version, repetitions)|
        projection = create(:driver_projection, driver_id: driver_id, aggregate_version: 0)
        event = build(:driver_event, driver_id: driver_id, aggregate_version: version)

        described_class.apply(event)
        state_after_first = observable_state(projection.reload)

        repetitions.times { described_class.apply(event) }

        expect(observable_state(projection.reload)).to eq(state_after_first)
      end
    end

    it 'não duplica efeito colateral externo em reentrega' do
      event = build(:driver_event, driver_id: driver_id, aggregate_version: 5)
      create(:driver_projection, driver_id: driver_id, aggregate_version: 0)

      expect(Sync::DispatchPoolNotifier).to receive(:driver_state_changed).once

      3.times { described_class.apply(event) }
    end

    it 'reprocessar o histórico completo converge para o estado atual' do
      property_of { Rantly { range(1, 30) } }.check do |length|
        events = build_event_sequence(driver_id: driver_id, length: length)
        create(:driver_projection, driver_id: driver_id, aggregate_version: 0)

        events.each { |e| described_class.apply(e) }
        state_after_first_pass = observable_state(Sync::DriverProjection.find_by(driver_id: driver_id))

        # Replay integral do log — exatamente o que ADR-05 permite fazer para
        # reparar uma projeção corrompida sem tocar no system of record.
        events.each { |e| described_class.apply(e) }

        expect(observable_state(Sync::DriverProjection.find_by(driver_id: driver_id)))
          .to eq(state_after_first_pass)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Princípio II — Convergência sob desordem
  # ---------------------------------------------------------------------------
  describe 'convergência sob desordem' do
    it 'qualquer permutação de entrega converge para o mesmo estado final' do
      property_of do
        Rantly { range(2, 25) }
      end.check do |length|
        events = build_event_sequence(driver_id: driver_id, length: length)

        create(:driver_projection, driver_id: driver_id, aggregate_version: 0)
        events.each { |e| described_class.apply(e) }
        canonical = observable_state(Sync::DriverProjection.find_by(driver_id: driver_id))

        3.times do
          Sync::DriverProjection.where(driver_id: driver_id).delete_all
          Sync::ProcessedEvent.where(driver_id: driver_id).delete_all
          create(:driver_projection, driver_id: driver_id, aggregate_version: 0)

          events.shuffle.each { |e| described_class.apply(e) }

          expect(observable_state(Sync::DriverProjection.find_by(driver_id: driver_id)))
            .to eq(canonical)
        end
      end
    end

    it 'a versão persistida nunca decresce, qualquer que seja a ordem de entrega' do
      property_of { Rantly { range(2, 25) } }.check do |length|
        events = build_event_sequence(driver_id: driver_id, length: length)
        projection = create(:driver_projection, driver_id: driver_id, aggregate_version: 0)

        observed = []
        events.shuffle.each do |event|
          described_class.apply(event)
          observed << projection.reload.aggregate_version
        end

        expect(observed).to eq(observed.sort), 'versão regrediu — guarda de versão furada'
        expect(observed.last).to eq(length)
      end
    end

    it 'o estado final é determinado pela ordem de EMISSÃO, não pela de chegada' do
      # Cenário C5 do spec, com a inversão que o desafio nomeia:
      # emitido ativado -> bloqueado, entregue bloqueado -> ativado.
      create(:driver_projection, driver_id: driver_id, aggregate_version: 0)

      activated = build(:driver_event, driver_id: driver_id, aggregate_version: 10, status: 'active')
      blocked   = build(:driver_event, driver_id: driver_id, aggregate_version: 11, status: 'blocked')

      described_class.apply(blocked)
      described_class.apply(activated)

      projection = Sync::DriverProjection.find_by(driver_id: driver_id)
      expect(projection.status).to eq('blocked')
      expect(projection.aggregate_version).to eq(11)
      expect(projection).not_to be_eligible
    end

    it 'ignora occurred_at como critério de ordenação, mesmo com clock skew' do
      # Um evento mais novo carregando relógio atrasado. Sob last-write-wins por
      # timestamp isto corromperia o estado silenciosamente (ADR-02).
      create(:driver_projection, driver_id: driver_id, aggregate_version: 0)

      old_version_recent_clock = build(:driver_event, driver_id: driver_id,
                                       aggregate_version: 3, status: 'active',
                                       occurred_at: Time.current + 1.hour)
      new_version_stale_clock  = build(:driver_event, driver_id: driver_id,
                                       aggregate_version: 4, status: 'blocked',
                                       occurred_at: Time.current - 1.hour)

      described_class.apply(old_version_recent_clock)
      described_class.apply(new_version_stale_clock)

      expect(Sync::DriverProjection.find_by(driver_id: driver_id).status).to eq('blocked')
    end
  end

  # ---------------------------------------------------------------------------
  # ADR-08 — Reconciliação não é caminho privilegiado
  # ---------------------------------------------------------------------------
  describe 'reconciliação versus evento ao vivo' do
    it 'snapshot lido antes de um evento aplicado não sobrescreve o estado mais novo' do
      # A armadilha do mecanismo de reparo virar mecanismo de corrupção:
      # snapshot lido às 14:00, evento de 14:03 aplicado, snapshot só chega às 14:08.
      property_of do
        Rantly { [range(1, 40), range(1, 20)] }
      end.check do |(snapshot_version, delta)|
        live_version = snapshot_version + delta

        create(:driver_projection, driver_id: driver_id, aggregate_version: 0)

        live_event = build(:driver_event, driver_id: driver_id,
                           aggregate_version: live_version, status: 'blocked')
        described_class.apply(live_event)

        snapshot = {
          'driver_id' => driver_id,
          'aggregate_version' => snapshot_version,
          'status' => 'active',
          'legal_entity_type' => 'company',
          'documents_status' => 'approved'
        }
        Sync::ReconciliationApplier.apply(snapshot)

        projection = Sync::DriverProjection.find_by(driver_id: driver_id)
        expect(projection.aggregate_version).to eq(live_version)
        expect(projection.status).to eq('blocked'),
                                     'reconciliação sobrescreveu evento mais recente'
      end
    end

    it 'exige aggregate_version no snapshot e recusa a aplicação sem ela' do
      # Guardrail contra a regressão mais provável desta API: alguém "simplifica"
      # o payload de reconciliação removendo a versão. Sem este teste, a remoção
      # passa verde e a corrupção só aparece em produção, sem rastro.
      snapshot = { 'driver_id' => driver_id, 'status' => 'active' }

      expect { Sync::ReconciliationApplier.apply(snapshot) }
        .to raise_error(Sync::MissingAggregateVersionError)
    end
  end
end
