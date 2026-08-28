# frozen_string_literal: true

# Fábricas do harness.
#
# Regra de projeto: nenhuma fábrica aqui produz um evento "válido por acidente".
# Cada trait existe para tornar *explícito* o cenário adversarial que ela representa,
# porque um teste cujo setup é opaco é um teste que um agente de IA consegue satisfazer
# sem entender o invariante que ele protege.

FactoryBot.define do
  factory :driver_projection, class: 'Sync::DriverProjection' do
    driver_id            { SecureRandom.uuid }
    aggregate_version    { 1 }
    status               { 'active' }
    legal_entity_type    { 'company' }
    documents_status     { 'approved' }
    vehicle_type         { 'motorcycle' }
    service_radius_km    { 15 }
    service_modes        { %w[goods] }
    last_synced_at       { Time.current }
    eligible             { true }
    evaluated_at_version { 1 }

    # Princípio VII: estado sincronizado tem prazo de validade.
    # Um entregador "ativo" cujo registro envelheceu não pode receber oferta —
    # é a defesa contra o bloqueio de segurança que nunca chegou.
    trait :stale do
      last_synced_at { Time.current - Sync::FRESHNESS_TTL - 1.second }
    end

    trait :blocked do
      status   { 'blocked' }
      eligible { false }
      ineligibility_reason { 'status_blocked' }
    end

    # Princípio V: o Portal aceita PF, a Ultra-rápida não.
    trait :individual do
      legal_entity_type    { 'individual' }
      eligible             { false }
      ineligibility_reason { 'legal_entity_type_not_allowed' }
    end
  end

  # ---------------------------------------------------------------------------
  # Eventos
  # ---------------------------------------------------------------------------

  factory :driver_event, class: 'Hash' do
    skip_create

    transient do
      driver_id         { SecureRandom.uuid }
      aggregate_version { 1 }
      event_type        { 'driver.status_changed' }
      status            { 'active' }
      legal_entity_type { 'company' }
      occurred_at       { Time.current }
    end

    initialize_with do
      {
        'event_id'          => SecureRandom.uuid_v7,
        'event_type'        => event_type,
        'event_version'     => '1.0',
        'driver_id'         => driver_id,
        'aggregate_version' => aggregate_version,
        'occurred_at'       => occurred_at.iso8601(3),
        'correlation_id'    => SecureRandom.uuid,
        'producer'          => 'portal-entregadores',
        'data' => {
          'status'            => status,
          'legal_entity_type' => legal_entity_type,
          'documents_status'  => 'approved',
          'vehicle_type'      => 'motorcycle',
          'service_radius_km' => 15,
          'service_modes'     => %w[goods]
        }
      }
    end

    # Duplicata exata: mesmo event_id, mesma versão.
    # É o que o broker entrega em rebalance de partição — não é exceção,
    # é comportamento normal (Princípio I).
    trait :duplicate_of do
      transient { original { nil } }
      initialize_with { original.deep_dup }
    end

    # Reentrega tardia: mesmo conteúdo lógico, event_id diferente.
    # A guarda de versão precisa descartar por versão, não por event_id —
    # deduplicação por id sozinha não cobre este caso.
    trait :stale_version do
      transient { aggregate_version { 1 } }
    end

    trait :signed_with_invalid_key do
      transient { signature { 'eyJhbGciOiJFUzI1NiJ9.forged.signature' } }
    end
  end
end

module HarnessHelpers
  # Constrói uma sequência causalmente coerente de eventos para um mesmo entregador,
  # com versões densas de 1..n. É a entrada canônica dos testes de propriedade:
  # a sequência tem uma ordem de emissão correta e conhecida, e o teste embaralha
  # a ordem de *entrega* para verificar que o resultado não muda.
  def build_event_sequence(driver_id:, length:)
    statuses = %w[pending approved active inactive blocked active]

    (1..length).map do |version|
      build(:driver_event,
            driver_id: driver_id,
            aggregate_version: version,
            status: statuses[(version - 1) % statuses.size])
    end
  end

  # Estado observável da projeção — o que o teste compara.
  # Exclui deliberadamente last_synced_at e updated_at: são carimbos de tempo
  # de processamento, não estado de domínio. Incluí-los faria toda comparação
  # falhar por motivo irrelevante e treinaria o time a ignorar o teste.
  def observable_state(projection)
    projection.slice(
      'driver_id', 'aggregate_version', 'status', 'legal_entity_type',
      'documents_status', 'vehicle_type', 'service_radius_km', 'service_modes',
      'eligible', 'ineligibility_reason'
    )
  end
end

RSpec.configure do |config|
  config.include FactoryBot::Syntax::Methods
  config.include HarnessHelpers
end
