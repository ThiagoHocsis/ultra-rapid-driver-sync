# frozen_string_literal: true

require 'rails_helper'

# Três filtros independentes governam quem recebe oferta. A propriedade que importa é que
# eles falham **fechado**: a falha de qualquer um resulta em não despachar, nunca em
# despachar indevidamente.
#
#   1. status == 'active'                         (fato vindo do Portal)
#   2. elegibilidade local                        (Princípio V — critério da Ultra-rápida)
#   3. frescor: last_synced_at dentro do TTL      (Princípio VII)

RSpec.describe Sync::DispatchPool do
  describe 'frescor verificável (Princípio VII)' do
    it 'exclui entregador ativo cujo estado envelheceu além do TTL' do
      # O caso que o fail-closed não cobre: o bloqueio de segurança foi emitido durante o
      # outage e nunca chegou. O consumidor não sabe que ele existe — manter o último
      # estado conhecido significaria manter ativo alguém que foi bloqueado.
      # A defesa é inverter o ônus da prova: o registro precisa provar que continua válido.
      stale = create(:driver_projection, :stale, status: 'active', eligible: true)

      expect(described_class.eligible_driver_ids).not_to include(stale.driver_id)
    end

    it 'readmite o entregador assim que a sincronização é confirmada' do
      driver = create(:driver_projection, :stale, status: 'active', eligible: true)
      expect(described_class.eligible_driver_ids).not_to include(driver.driver_id)

      Sync::EventApplier.apply(
        build(:driver_event, driver_id: driver.driver_id,
              aggregate_version: driver.aggregate_version + 1, status: 'active')
      )

      expect(described_class.eligible_driver_ids).to include(driver.driver_id)
    end

    it 'o heartbeat renova o frescor sem que haja mudança cadastral' do
      # Sem heartbeat, um entregador ativo e sem alterações cairia do pool a cada TTL —
      # o mecanismo de segurança viraria uma fonte de indisponibilidade operacional.
      driver = create(:driver_projection, :stale, status: 'active', eligible: true)

      Sync::HeartbeatApplier.confirm(driver_id: driver.driver_id,
                                     aggregate_version: driver.aggregate_version)

      expect(described_class.eligible_driver_ids).to include(driver.driver_id)
      expect(driver.reload.aggregate_version).to eq(driver.aggregate_version),
                                                 'heartbeat não pode alterar versão do agregado'
    end

    it 'nenhuma combinação de status e elegibilidade sobrepõe o TTL' do
      %w[pending approved active inactive blocked].product([true, false]).each do |status, eligible|
        driver = create(:driver_projection, :stale, status: status, eligible: eligible)
        expect(described_class.eligible_driver_ids).not_to include(driver.driver_id),
                                                           "status=#{status} eligible=#{eligible} furou o TTL"
      end
    end
  end

  describe 'elegibilidade na borda (Princípio V)' do
    it 'recusa pessoa física aprovada no Portal' do
      driver = create(:driver_projection, :individual, status: 'active')

      expect(described_class.eligible_driver_ids).not_to include(driver.driver_id)
      expect(driver.ineligibility_reason).to eq('legal_entity_type_not_allowed')
    end

    it 'registra motivo e versão de origem de toda recusa (RF-06)' do
      # Sem isto, "por que este entregador não recebeu oferta às 14h32?" é
      # irrespondível — e é a pergunta que a operação faz.
      driver = create(:driver_projection, driver_id: SecureRandom.uuid, aggregate_version: 0)

      Sync::EventApplier.apply(
        build(:driver_event, driver_id: driver.driver_id, aggregate_version: 9,
              status: 'active', legal_entity_type: 'individual')
      )

      driver.reload
      expect(driver).not_to be_eligible
      expect(driver.ineligibility_reason).to be_present
      expect(driver.evaluated_at_version).to eq(9)
    end

    it 'inelegibilidade não é falha: não retenta e não vai para DLQ' do
      # Confundir decisão de negócio com falha técnica enche a DLQ de ruído e
      # esconde as falhas reais.
      event = build(:driver_event, aggregate_version: 1, legal_entity_type: 'individual')

      expect { Sync::EventApplier.apply(event) }.not_to raise_error
      expect(Sync::DeadLetterQueue.size).to eq(0)
    end
  end

  describe 'fail-closed' do
    it 'entregador sem projeção local nunca é elegível' do
      # Ativação emitida durante indisponibilidade: o dado não chegou.
      # Ausência de informação é negação, nunca permissão.
      expect(described_class.eligible?(SecureRandom.uuid)).to be(false)
    end

    it 'projeção corrompida ou incompleta resulta em recusa, não em exceção' do
      broken = create(:driver_projection, status: 'active', eligible: true,
                      legal_entity_type: nil, documents_status: nil)

      expect(described_class.eligible?(broken.driver_id)).to be(false)
    end
  end
end
