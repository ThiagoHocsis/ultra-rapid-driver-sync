# frozen_string_literal: true

require 'rails_helper'
require 'json_schemer'

# Conformidade ao contrato (Princípio IV).
#
# Produtor e consumidor são validados contra o AsyncAPI, nunca um contra o outro. Testar
# produtor contra consumidor cria um acordo bilateral invisível: os dois evoluem juntos,
# a suíte fica verde, e o terceiro consumidor do ecossistema quebra em produção sem que
# ninguém tenha alterado o contrato publicado.

RSpec.describe 'conformidade ao contrato de eventos' do
  ASYNCAPI = YAML.load_file(
    Rails.root.join('specs/001-driver-sync-engine/contracts/asyncapi.yaml')
  ).freeze

  def schema_for(message_name)
    JSONSchemer.schema(ASYNCAPI.dig('components', 'schemas', "#{message_name}Payload"))
  end

  describe 'produtor' do
    %w[DriverCreated DriverUpdated DriverStatusChanged].each do |message|
      it "emite #{message} conforme o schema publicado" do
        payload = Portal::EventBuilder.build(message.underscore.tr('_', '.'))
        errors  = schema_for(message).validate(payload).to_a

        expect(errors).to be_empty, errors.map { |e| e['error'] }.join("\n")
      end
    end

    it 'não emite PII em claro no payload (Princípio VIII, LGPD)' do
      # Varredura de conteúdo, não de nome de campo: um agente que renomeasse
      # `cpf` para `identifier` passaria numa checagem por nome.
      pii_patterns = {
        cpf: /\b\d{3}\.?\d{3}\.?\d{3}-?\d{2}\b/,
        cnpj: /\b\d{2}\.?\d{3}\.?\d{3}\/?\d{4}-?\d{2}\b/,
        iban_like: /\b\d{4,}-?\d{1,2}\b/
      }

      payload = Portal::EventBuilder.build('driver.created').to_json

      pii_patterns.each do |kind, pattern|
        expect(payload).not_to match(pattern), "possível #{kind} em claro no evento"
      end
    end

    it 'todo evento carrega os campos de rastreabilidade (Princípio IX)' do
      payload = Portal::EventBuilder.build('driver.updated')

      expect(payload).to include('event_id', 'correlation_id', 'aggregate_version', 'occurred_at')
      expect(payload['event_id']).to match(/\A[0-9a-f-]{36}\z/)
    end
  end

  describe 'consumidor' do
    it 'aceita todo exemplo publicado no contrato' do
      # Os exemplos do AsyncAPI não são decoração: são casos de teste executáveis.
      # Exemplo que não passa no consumidor é contrato mentindo.
      ASYNCAPI['components']['messages'].each_value do |message|
        Array(message['examples']).each do |example|
          expect { Sync::EventApplier.apply(example['payload']) }
            .not_to raise_error, "exemplo #{example['name']} rejeitado pelo consumidor"
        end
      end
    end

    it 'tolera campo opcional desconhecido (compatibilidade para frente)' do
      # O consumidor N+1 do ecossistema pode receber um evento de uma versão mais nova
      # do produtor. Adicionar campo opcional é mudança compatível — quebrar aqui
      # tornaria toda evolução do contrato um deploy coordenado entre N times.
      event = build(:driver_event, aggregate_version: 1)
      event['data']['future_field'] = 'valor que este consumidor não conhece'

      expect { Sync::EventApplier.apply(event) }.not_to raise_error
    end

    it 'rejeita evento com assinatura inválida sem retentar' do
      # Evento forjado não melhora com retry. Retentar seria transformar uma
      # tentativa de ataque em amplificação de carga.
      event = build(:driver_event, :signed_with_invalid_key, aggregate_version: 1)

      expect { Sync::EventApplier.apply(event) }
        .to raise_error(Sync::InvalidSignatureError)
      expect(Sync::RetryScheduler.scheduled_for(event['event_id'])).to be_nil
      expect(Sync::Metrics.counter('events.rejected', reason: 'invalid_signature')).to eq(1)
    end
  end

  describe 'evolução do contrato' do
    it 'detecta mudança incompatível contra a versão publicada em produção' do
      # Gate de CI: comparar o contrato do PR com o do último release.
      # Um agente refatorando schema não distingue "campo que ninguém usa" de
      # "campo que três consumidores leem" — a distinção precisa vir do CI.
      diff = ContractDiff.new(
        base: ContractRegistry.published('drivers.lifecycle.v1'),
        head: ASYNCAPI
      )

      expect(diff.breaking_changes).to be_empty, <<~MSG
        Mudança incompatível sem bump de major:
        #{diff.breaking_changes.map { |c| "  - #{c}" }.join("\n")}

        Compatível: adicionar campo opcional, adicionar valor a enum de saída.
        Incompatível: remover campo, renomear, estreitar tipo, restringir enum de entrada,
        tornar obrigatório um campo opcional.
      MSG
    end
  end
end
