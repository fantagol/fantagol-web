-- =============================================================================
-- FANTAGOL
-- Migration: 130_commercial_provider_secret_backend_reference_resolution_gateway_lifecycle_certification.sql
-- Milestone: Commercial Platform - Secret Backend Reference Resolution Gateway
--
-- Purpose:
--   Transactionally certify the complete passive lifecycle introduced by
--   migration 129 against a temporary, fully validated backend registry chain.
--
--   The certification covers:
--     - temporary backend/version/capability/binding preparation
--     - idempotent gateway request intake and replay
--     - deterministic binding/backend/version selection
--     - namespace and passive capability validation
--     - accepted routing-metadata decision
--     - held opaque-reference route manifest
--     - blocked execution attempt
--     - read-model integrity
--     - immutable/append-only and sensitive-data guards
--     - zero economic/runtime mutation
--
--   The complete certification ends with ROLLBACK.
-- =============================================================================

\set ON_ERROR_STOP on
\timing on

begin;

set local statement_timeout = '120s';
set local lock_timeout = '15s';
set local idle_in_transaction_session_timeout = '180s';

do $$
declare
  -- Registry prerequisites
  v_registry_policy public.commercial_secret_backend_registry_policies;
  v_orchestrator_policy public.commercial_secret_resolution_policies;
  v_gateway_policy public.commercial_secret_reference_gateway_policies;

  v_backend public.commercial_secret_backends;
  v_backend_version public.commercial_secret_backend_versions;
  v_binding public.commercial_secret_backend_bindings;

  -- Gateway lifecycle
  v_request public.commercial_secret_reference_gateway_requests;
  v_replayed_request public.commercial_secret_reference_gateway_requests;
  v_candidate public.commercial_secret_reference_gateway_candidates;
  v_decision public.commercial_secret_reference_gateway_decisions;
  v_manifest public.commercial_secret_reference_route_manifests;
  v_attempt public.commercial_secret_reference_gateway_attempts;
  v_read_model public.commercial_secret_reference_gateway_read_model;
  v_idempotency public.commercial_secret_reference_gateway_idempotency;

  -- Temporary identifiers
  v_suffix text := lower(substr(replace(gen_random_uuid()::text,'-',''),1,12));
  v_backend_code text;
  v_backend_name text;
  v_reference_namespace text;
  v_binding_key text;
  v_request_key text;
  v_idempotency_key text;
  v_correlation_id uuid := gen_random_uuid();
  v_causation_id uuid := gen_random_uuid();

  v_reference_fingerprint text :=
    encode(extensions.digest(gen_random_uuid()::text,'sha256'),'hex');
  v_contract_hash text :=
    encode(extensions.digest(gen_random_uuid()::text,'sha256'),'hex');
  v_reference_schema_hash text :=
    encode(extensions.digest(gen_random_uuid()::text,'sha256'),'hex');

  -- Counts
  v_backend_count bigint;
  v_version_count bigint;
  v_capability_count bigint;
  v_validated_capability_count bigint;
  v_binding_count bigint;
  v_validated_binding_count bigint;

  v_request_count bigint;
  v_idempotency_count bigint;
  v_candidate_count bigint;
  v_decision_count bigint;
  v_manifest_count bigint;
  v_attempt_count bigint;
  v_receipt_count bigint;
  v_event_count bigint;

  -- Guards
  v_idempotency_conflict_guard boolean := false;
  v_policy_guard boolean := false;
  v_candidate_guard boolean := false;
  v_decision_guard boolean := false;
  v_manifest_guard boolean := false;
  v_receipt_guard boolean := false;
  v_event_guard boolean := false;
  v_plaintext_guard boolean := false;
  v_endpoint_guard boolean := false;
  v_active_manifest_guard boolean := false;
  v_active_attempt_guard boolean := false;

  -- Economic/runtime baselines
  v_purchase_before bigint;
  v_checkout_session_before bigint;
  v_provider_request_before bigint;
  v_callback_before bigint;
  v_reconciliation_before bigint;
  v_wallet_before bigint;
  v_ledger_before bigint;
  v_outbox_before bigint;

  v_purchase_after bigint;
  v_checkout_session_after bigint;
  v_provider_request_after bigint;
  v_callback_after bigint;
  v_reconciliation_after bigint;
  v_wallet_after bigint;
  v_ledger_after bigint;
  v_outbox_after bigint;
begin
  -- ===========================================================================
  -- 1. DEPENDENCY AND POLICY ASSERTIONS
  -- ===========================================================================

  if to_regclass('public.commercial_secret_reference_gateway_policies') is null
     or to_regclass('public.commercial_secret_reference_gateway_requests') is null
     or to_regclass('public.commercial_secret_reference_gateway_idempotency') is null
     or to_regclass('public.commercial_secret_reference_gateway_candidates') is null
     or to_regclass('public.commercial_secret_reference_gateway_decisions') is null
     or to_regclass('public.commercial_secret_reference_route_manifests') is null
     or to_regclass('public.commercial_secret_reference_gateway_attempts') is null
     or to_regclass('public.commercial_secret_reference_gateway_receipts') is null
     or to_regclass('public.commercial_secret_reference_gateway_events') is null
     or to_regclass('public.commercial_secret_reference_gateway_read_model') is null then
    raise exception 'MIGRATION_130_REQUIRES_MIGRATION_129_OBJECTS';
  end if;

  if to_regprocedure(
       'public.enqueue_commercial_secret_reference_gateway_request(text,text,uuid,uuid,text,text,text,text,text,uuid,uuid,jsonb)'
     ) is null
     or to_regprocedure(
       'public.evaluate_commercial_secret_reference_gateway_request(uuid,text)'
     ) is null
     or to_regprocedure(
       'public.build_commercial_secret_reference_route_manifest(uuid,text)'
     ) is null
     or to_regprocedure(
       'public.record_blocked_secret_reference_gateway_attempt(uuid,text,text)'
     ) is null then
    raise exception 'MIGRATION_130_REQUIRES_MIGRATION_129_FUNCTIONS';
  end if;

  select * into strict v_registry_policy
  from public.commercial_secret_backend_registry_policies
  where policy_code='commercial:provider_secret_backend_registry:v1'
    and environment='production'
    and policy_status='approved';

  select * into strict v_orchestrator_policy
  from public.commercial_secret_resolution_policies
  where policy_code='commercial:provider_secret_resolution:v1'
    and environment='production'
    and policy_status='approved';

  select * into strict v_gateway_policy
  from public.commercial_secret_reference_gateway_policies
  where policy_code='commercial:provider_secret_reference_gateway:v1'
    and environment='production'
    and policy_status='approved';

  if v_gateway_policy.intake_enabled is not true
     or v_gateway_policy.idempotency_enabled is not true
     or v_gateway_policy.policy_evaluation_enabled is not true
     or v_gateway_policy.binding_selection_enabled is not true
     or v_gateway_policy.namespace_validation_enabled is not true
     or v_gateway_policy.capability_validation_enabled is not true
     or v_gateway_policy.route_manifest_generation_enabled is not true
     or v_gateway_policy.blocked_attempt_recording_enabled is not true then
    raise exception 'MIGRATION_130_PASSIVE_GATEWAY_CAPABILITIES_DISABLED';
  end if;

  if v_gateway_policy.automatic_dispatch_enabled
     or v_gateway_policy.endpoint_discovery_enabled
     or v_gateway_policy.backend_probe_enabled
     or v_gateway_policy.backend_contact_enabled
     or v_gateway_policy.backend_authentication_enabled
     or v_gateway_policy.secret_lookup_enabled
     or v_gateway_policy.secret_resolution_enabled
     or v_gateway_policy.secret_decryption_enabled
     or v_gateway_policy.credential_material_loading_enabled
     or v_gateway_policy.credential_delivery_enabled
     or v_gateway_policy.network_access_enabled then
    raise exception 'MIGRATION_130_UNSAFE_GATEWAY_POLICY';
  end if;

  -- ===========================================================================
  -- 2. ECONOMIC/RUNTIME BASELINES
  -- ===========================================================================

  select count(*) into v_purchase_before
  from public.commercial_purchases;

  select count(*) into v_checkout_session_before
  from public.commercial_checkout_sessions;

  select count(*) into v_provider_request_before
  from public.commercial_checkout_provider_requests;

  select count(*) into v_callback_before
  from public.commercial_checkout_callbacks;

  select count(*) into v_reconciliation_before
  from public.commercial_checkout_reconciliation_observations;

  select count(*) into v_wallet_before
  from public.commercial_wallets;

  select count(*) into v_ledger_before
  from public.commercial_ledger;

  select count(*) into v_outbox_before
  from public.commercial_purchase_runtime_outbox;

  -- ===========================================================================
  -- 3. TEMPORARY VALIDATED BACKEND REGISTRY CHAIN
  -- ===========================================================================

  v_backend_code := 'migration_130_backend_' || v_suffix;
  v_backend_name := 'Migration 130 Passive Backend ' || upper(v_suffix);
  v_reference_namespace := 'migration_130:opaque:' || v_suffix;
  v_binding_key := 'migration_130:binding:' || v_suffix;

  v_backend := public.register_commercial_secret_backend(
    v_backend_code,
    v_backend_name,
    'development_stub',
    'production',
    'platform',
    null,
    null,
    'unspecified',
    v_reference_namespace,
    v_reference_fingerprint,
    'MIGRATION_130',
    v_correlation_id,
    jsonb_build_object(
      'temporary',true,
      'certification','MIGRATION_130',
      'opaque_references_only',true
    )
  );

  v_backend_version := public.register_commercial_secret_backend_version(
    v_backend.id,
    1,
    'FantaGol Passive Reference Gateway Contract',
    '1.0.0',
    v_contract_hash,
    v_reference_schema_hash,
    true,
    true,
    true,
    true,
    'MIGRATION_130',
    v_correlation_id,
    jsonb_build_object(
      'temporary',true,
      'certification','MIGRATION_130',
      'passive_only',true
    )
  );

  perform public.register_commercial_secret_backend_capability(
    v_backend_version.id,'reference_validation','reference_validation',
    'MIGRATION_130',v_correlation_id,
    jsonb_build_object('temporary',true,'offline_only',true)
  );

  perform public.register_commercial_secret_backend_capability(
    v_backend_version.id,'versioned_references','version_metadata',
    'MIGRATION_130',v_correlation_id,
    jsonb_build_object('temporary',true,'offline_only',true)
  );

  perform public.register_commercial_secret_backend_capability(
    v_backend_version.id,'rotation_metadata','rotation_metadata',
    'MIGRATION_130',v_correlation_id,
    jsonb_build_object('temporary',true,'offline_only',true)
  );

  perform public.register_commercial_secret_backend_capability(
    v_backend_version.id,'expiry_metadata','expiry_metadata',
    'MIGRATION_130',v_correlation_id,
    jsonb_build_object('temporary',true,'offline_only',true)
  );

  perform public.register_commercial_secret_backend_capability(
    v_backend_version.id,'scope_metadata','scope_metadata',
    'MIGRATION_130',v_correlation_id,
    jsonb_build_object('temporary',true,'offline_only',true)
  );

  v_backend_version := public.validate_commercial_secret_backend_version(
    v_backend_version.id,'MIGRATION_130',v_correlation_id
  );

  select * into strict v_backend
  from public.commercial_secret_backends
  where id=v_backend.id;

  if v_backend.backend_status <> 'validated'
     or v_backend.trust_tier <> 'validated'
     or v_backend.active_version_id <> v_backend_version.id
     or v_backend_version.version_status <> 'validated' then
    raise exception 'MIGRATION_130_BACKEND_CHAIN_VALIDATION_FAILED';
  end if;

  v_binding := public.register_commercial_secret_backend_binding(
    v_binding_key,
    v_backend.id,
    v_backend_version.id,
    null,
    v_orchestrator_policy.id,
    'platform',
    100,
    v_reference_namespace,
    'MIGRATION_130',
    v_correlation_id,
    jsonb_build_object(
      'temporary',true,
      'certification','MIGRATION_130',
      'passive_only',true
    )
  );

  v_binding := public.validate_commercial_secret_backend_binding(
    v_binding.id,'MIGRATION_130',v_correlation_id
  );

  if v_binding.binding_status <> 'validated'
     or v_binding.backend_contact_allowed
     or v_binding.authentication_allowed
     or v_binding.secret_lookup_allowed
     or v_binding.secret_resolution_allowed
     or v_binding.decryption_allowed
     or v_binding.material_loading_allowed
     or v_binding.delivery_allowed
     or v_binding.network_access_allowed then
    raise exception 'MIGRATION_130_BACKEND_BINDING_VALIDATION_FAILED';
  end if;

  raise notice
    'MIGRATION_130_TEMPORARY_BACKEND_CHAIN_CREATED backend_id=%, version_id=%, binding_id=%, namespace=%',
    v_backend.id,v_backend_version.id,v_binding.id,v_reference_namespace;

  -- ===========================================================================
  -- 4. IDEMPOTENT REQUEST INTAKE
  -- ===========================================================================

  v_request_key := 'migration_130:request:' || v_suffix;
  v_idempotency_key := 'migration_130:idempotency:' || v_suffix;

  v_request := public.enqueue_commercial_secret_reference_gateway_request(
    v_request_key,
    v_idempotency_key,
    null,
    null,
    'production',
    v_reference_namespace,
    'reference_validation',
    'platform',
    'MIGRATION_130',
    v_correlation_id,
    v_causation_id,
    jsonb_build_object(
      'temporary',true,
      'certification','MIGRATION_130',
      'opaque_references_only',true
    )
  );

  if v_request.request_status <> 'received'
     or v_request.requested_namespace <> v_reference_namespace
     or v_request.requested_capability <> 'reference_validation'
     or v_request.requested_scope <> 'platform'
     or v_request.requested_operation <> 'route_reference' then
    raise exception 'MIGRATION_130_REQUEST_INTAKE_FAILED';
  end if;

  v_replayed_request := public.enqueue_commercial_secret_reference_gateway_request(
    v_request_key,
    v_idempotency_key,
    null,
    null,
    'production',
    v_reference_namespace,
    'reference_validation',
    'platform',
    'MIGRATION_130',
    v_correlation_id,
    v_causation_id,
    jsonb_build_object(
      'temporary',true,
      'certification','MIGRATION_130',
      'opaque_references_only',true
    )
  );

  if v_replayed_request.id <> v_request.id then
    raise exception 'MIGRATION_130_IDEMPOTENT_REPLAY_CREATED_DUPLICATE';
  end if;

  select * into strict v_idempotency
  from public.commercial_secret_reference_gateway_idempotency
  where gateway_request_id=v_request.id;

  if v_idempotency.replay_count <> 1 then
    raise exception
      'MIGRATION_130_IDEMPOTENT_REPLAY_COUNT_FAILED replay_count=%',
      v_idempotency.replay_count;
  end if;

  begin
    perform public.enqueue_commercial_secret_reference_gateway_request(
      v_request_key,
      v_idempotency_key,
      null,
      null,
      'production',
      v_reference_namespace,
      'scope_metadata',
      'platform',
      'MIGRATION_130',
      v_correlation_id,
      v_causation_id,
      jsonb_build_object(
        'temporary',true,
        'certification','MIGRATION_130',
        'opaque_references_only',true
      )
    );

    raise exception 'MIGRATION_130_IDEMPOTENCY_CONFLICT_NOT_ENFORCED';
  exception
    when others then
      if sqlerrm='COMMERCIAL_SECRET_REFERENCE_GATEWAY_IDEMPOTENCY_CONFLICT' then
        v_idempotency_conflict_guard := true;
      else
        raise;
      end if;
  end;

  -- ===========================================================================
  -- 5. DETERMINISTIC EVALUATION
  -- ===========================================================================

  v_decision := public.evaluate_commercial_secret_reference_gateway_request(
    v_request.id,'MIGRATION_130'
  );

  if v_decision.decision_status <> 'accepted'
     or v_decision.decision_code <> 'ROUTE_METADATA_ACCEPTED'
     or v_decision.selected_backend_binding_id <> v_binding.id
     or v_decision.selected_backend_id <> v_backend.id
     or v_decision.selected_backend_version_id <> v_backend_version.id
     or v_decision.selected_orchestrator_policy_id <> v_orchestrator_policy.id
     or v_decision.requested_namespace <> v_reference_namespace
     or v_decision.resolved_namespace <> v_reference_namespace
     or v_decision.requested_capability <> 'reference_validation'
     or v_decision.capability_available is not true then
    raise exception
      'MIGRATION_130_DECISION_FAILED status=%, code=%, binding=%, backend=%, version=%, namespace=%',
      v_decision.decision_status,v_decision.decision_code,
      v_decision.selected_backend_binding_id,v_decision.selected_backend_id,
      v_decision.selected_backend_version_id,v_decision.resolved_namespace;
  end if;

  if v_decision.backend_contact_allowed
     or v_decision.authentication_allowed
     or v_decision.secret_lookup_allowed
     or v_decision.secret_resolution_allowed
     or v_decision.decryption_allowed
     or v_decision.material_loading_allowed
     or v_decision.delivery_allowed
     or v_decision.network_access_allowed then
    raise exception 'MIGRATION_130_DECISION_SAFETY_FAILED';
  end if;

  select * into strict v_candidate
  from public.commercial_secret_reference_gateway_candidates
  where gateway_request_id=v_request.id;

  if v_candidate.candidate_rank <> 1
     or v_candidate.secret_backend_binding_id <> v_binding.id
     or v_candidate.candidate_status <> 'eligible'
     or v_candidate.binding_status <> 'validated'
     or v_candidate.backend_status <> 'validated'
     or v_candidate.backend_trust_tier <> 'validated'
     or v_candidate.backend_version_status <> 'validated'
     or v_candidate.reference_namespace <> v_reference_namespace
     or v_candidate.capability_available is not true then
    raise exception 'MIGRATION_130_CANDIDATE_SNAPSHOT_FAILED';
  end if;

  -- ===========================================================================
  -- 6. HELD ROUTE MANIFEST
  -- ===========================================================================

  v_manifest := public.build_commercial_secret_reference_route_manifest(
    v_request.id,'MIGRATION_130'
  );

  if v_manifest.manifest_status <> 'held'
     or v_manifest.route_class <> 'opaque_reference_metadata'
     or v_manifest.backend_code <> v_backend.backend_code
     or v_manifest.backend_type <> v_backend.backend_type
     or v_manifest.backend_contract_name <> v_backend_version.contract_name
     or v_manifest.backend_contract_version <> v_backend_version.contract_version
     or v_manifest.reference_namespace <> v_reference_namespace
     or v_manifest.capability_code <> 'reference_validation'
     or v_manifest.binding_priority <> v_binding.priority then
    raise exception 'MIGRATION_130_ROUTE_MANIFEST_FAILED';
  end if;

  if v_manifest.dispatch_allowed
     or v_manifest.endpoint_discovery_allowed
     or v_manifest.backend_probe_allowed
     or v_manifest.backend_contact_allowed
     or v_manifest.authentication_allowed
     or v_manifest.secret_lookup_allowed
     or v_manifest.secret_resolution_allowed
     or v_manifest.decryption_allowed
     or v_manifest.material_loading_allowed
     or v_manifest.delivery_allowed
     or v_manifest.network_access_allowed then
    raise exception 'MIGRATION_130_ROUTE_MANIFEST_SAFETY_FAILED';
  end if;

  -- ===========================================================================
  -- 7. BLOCKED EXECUTION ATTEMPT
  -- ===========================================================================

  v_attempt := public.record_blocked_secret_reference_gateway_attempt(
    v_request.id,
    'MIGRATION_130',
    'PASSIVE_REFERENCE_GATEWAY_EXECUTION_DISABLED'
  );

  if v_attempt.attempt_number <> 1
     or v_attempt.attempt_status <> 'blocked'
     or v_attempt.normalized_error_code <>
        'SECRET_REFERENCE_GATEWAY_EXECUTION_DISABLED'
     or v_attempt.retry_class <> 'never'
     or v_attempt.dispatch_requested
     or v_attempt.dispatch_performed
     or v_attempt.endpoint_discovery_requested
     or v_attempt.endpoint_discovery_performed
     or v_attempt.backend_contact_requested
     or v_attempt.backend_contact_performed
     or v_attempt.authentication_requested
     or v_attempt.authentication_performed
     or v_attempt.secret_lookup_requested
     or v_attempt.secret_lookup_performed
     or v_attempt.secret_material_observed
     or v_attempt.network_attempted then
    raise exception 'MIGRATION_130_BLOCKED_ATTEMPT_FAILED';
  end if;

  -- ===========================================================================
  -- 8. READ MODEL AND EXACT COUNTS
  -- ===========================================================================

  select * into strict v_read_model
  from public.commercial_secret_reference_gateway_read_model
  where gateway_request_id=v_request.id;

  if v_read_model.request_status <> 'held'
     or v_read_model.decision_status <> 'accepted'
     or v_read_model.decision_code <> 'ROUTE_METADATA_ACCEPTED'
     or v_read_model.manifest_status <> 'held'
     or v_read_model.route_class <> 'opaque_reference_metadata'
     or v_read_model.selected_backend_binding_id <> v_binding.id
     or v_read_model.selected_backend_id <> v_backend.id
     or v_read_model.selected_backend_version_id <> v_backend_version.id
     or v_read_model.resolved_namespace <> v_reference_namespace
     or v_read_model.capability_available is not true
     or v_read_model.candidate_count <> 1
     or v_read_model.attempt_count <> 1
     or v_read_model.receipt_count <> 5
     or v_read_model.event_count <> 5
     or v_read_model.replay_count <> 1
     or v_read_model.dispatch_allowed
     or v_read_model.endpoint_discovery_allowed
     or v_read_model.backend_probe_allowed
     or v_read_model.backend_contact_allowed
     or v_read_model.authentication_allowed
     or v_read_model.secret_lookup_allowed
     or v_read_model.secret_resolution_allowed
     or v_read_model.decryption_allowed
     or v_read_model.material_loading_allowed
     or v_read_model.delivery_allowed
     or v_read_model.network_access_allowed then
    raise exception
      'MIGRATION_130_READ_MODEL_FAILED status=%, decision=%/%, manifest=%, candidates=%, attempts=%, receipts=%, events=%, replay=%',
      v_read_model.request_status,v_read_model.decision_status,
      v_read_model.decision_code,v_read_model.manifest_status,
      v_read_model.candidate_count,v_read_model.attempt_count,
      v_read_model.receipt_count,v_read_model.event_count,
      v_read_model.replay_count;
  end if;

  select count(*) into v_backend_count
  from public.commercial_secret_backends
  where id=v_backend.id;

  select count(*) into v_version_count
  from public.commercial_secret_backend_versions
  where secret_backend_id=v_backend.id;

  select count(*) into v_capability_count
  from public.commercial_secret_backend_capabilities
  where secret_backend_version_id=v_backend_version.id;

  select count(*) into v_validated_capability_count
  from public.commercial_secret_backend_capabilities
  where secret_backend_version_id=v_backend_version.id
    and capability_status='validated';

  select count(*) into v_binding_count
  from public.commercial_secret_backend_bindings
  where secret_backend_id=v_backend.id;

  select count(*) into v_validated_binding_count
  from public.commercial_secret_backend_bindings
  where secret_backend_id=v_backend.id
    and binding_status='validated';

  select count(*) into v_request_count
  from public.commercial_secret_reference_gateway_requests
  where id=v_request.id;

  select count(*) into v_idempotency_count
  from public.commercial_secret_reference_gateway_idempotency
  where gateway_request_id=v_request.id;

  select count(*) into v_candidate_count
  from public.commercial_secret_reference_gateway_candidates
  where gateway_request_id=v_request.id;

  select count(*) into v_decision_count
  from public.commercial_secret_reference_gateway_decisions
  where gateway_request_id=v_request.id;

  select count(*) into v_manifest_count
  from public.commercial_secret_reference_route_manifests
  where gateway_request_id=v_request.id;

  select count(*) into v_attempt_count
  from public.commercial_secret_reference_gateway_attempts
  where gateway_request_id=v_request.id;

  select count(*) into v_receipt_count
  from public.commercial_secret_reference_gateway_receipts
  where gateway_request_id=v_request.id;

  select count(*) into v_event_count
  from public.commercial_secret_reference_gateway_events
  where gateway_request_id=v_request.id;

  if v_backend_count <> 1
     or v_version_count <> 1
     or v_capability_count <> 5
     or v_validated_capability_count <> 5
     or v_binding_count <> 1
     or v_validated_binding_count <> 1
     or v_request_count <> 1
     or v_idempotency_count <> 1
     or v_candidate_count <> 1
     or v_decision_count <> 1
     or v_manifest_count <> 1
     or v_attempt_count <> 1
     or v_receipt_count <> 5
     or v_event_count <> 5 then
    raise exception
      'MIGRATION_130_COUNT_ASSERTION_FAILED backend=%, version=%, capability=%, validated_capability=%, binding=%, validated_binding=%, request=%, idempotency=%, candidate=%, decision=%, manifest=%, attempt=%, receipt=%, event=%',
      v_backend_count,v_version_count,v_capability_count,
      v_validated_capability_count,v_binding_count,v_validated_binding_count,
      v_request_count,v_idempotency_count,v_candidate_count,
      v_decision_count,v_manifest_count,v_attempt_count,
      v_receipt_count,v_event_count;
  end if;

  -- ===========================================================================
  -- 9. IMMUTABILITY AND APPEND-ONLY GUARDS
  -- ===========================================================================

  begin
    update public.commercial_secret_reference_gateway_policies
    set maximum_candidates=maximum_candidates+1
    where id=v_gateway_policy.id;

    raise exception 'MIGRATION_130_POLICY_GUARD_NOT_ENFORCED';
  exception
    when others then
      if sqlerrm='COMMERCIAL_SECRET_REFERENCE_GATEWAY_POLICY_IMMUTABLE' then
        v_policy_guard := true;
      else
        raise;
      end if;
  end;

  begin
    update public.commercial_secret_reference_gateway_candidates
    set candidate_rank=2
    where id=v_candidate.id;

    raise exception 'MIGRATION_130_CANDIDATE_GUARD_NOT_ENFORCED';
  exception
    when others then
      if sqlerrm='COMMERCIAL_SECRET_REFERENCE_GATEWAY_CANDIDATE_IMMUTABLE' then
        v_candidate_guard := true;
      else
        raise;
      end if;
  end;

  begin
    update public.commercial_secret_reference_gateway_decisions
    set decision_reason='MUTATED'
    where id=v_decision.id;

    raise exception 'MIGRATION_130_DECISION_GUARD_NOT_ENFORCED';
  exception
    when others then
      if sqlerrm='COMMERCIAL_SECRET_REFERENCE_GATEWAY_DECISION_IMMUTABLE' then
        v_decision_guard := true;
      else
        raise;
      end if;
  end;

  begin
    update public.commercial_secret_reference_route_manifests
    set binding_priority=binding_priority+1
    where id=v_manifest.id;

    raise exception 'MIGRATION_130_MANIFEST_GUARD_NOT_ENFORCED';
  exception
    when others then
      if sqlerrm='COMMERCIAL_SECRET_REFERENCE_ROUTE_MANIFEST_IMMUTABLE' then
        v_manifest_guard := true;
      else
        raise;
      end if;
  end;

  begin
    update public.commercial_secret_reference_gateway_receipts
    set receipt_status='accepted'
    where gateway_request_id=v_request.id;

    raise exception 'MIGRATION_130_RECEIPT_GUARD_NOT_ENFORCED';
  exception
    when others then
      if sqlerrm='COMMERCIAL_SECRET_REFERENCE_GATEWAY_RECEIPT_APPEND_ONLY' then
        v_receipt_guard := true;
      else
        raise;
      end if;
  end;

  begin
    delete from public.commercial_secret_reference_gateway_events
    where gateway_request_id=v_request.id;

    raise exception 'MIGRATION_130_EVENT_GUARD_NOT_ENFORCED';
  exception
    when others then
      if sqlerrm='COMMERCIAL_SECRET_REFERENCE_GATEWAY_EVENT_APPEND_ONLY' then
        v_event_guard := true;
      else
        raise;
      end if;
  end;

  -- ===========================================================================
  -- 10. SENSITIVE-DATA AND ACTIVE-EXECUTION GUARDS
  -- ===========================================================================

  begin
    insert into public.commercial_secret_reference_gateway_requests (
      request_key,idempotency_key,gateway_policy_id,requested_environment,
      requested_namespace,requested_capability,requested_scope,
      requested_operation,request_status,correlation_id,requested_by,
      request_metadata,request_hash
    ) values (
      'migration_130:plaintext:'||v_suffix,
      'migration_130:plaintext_idem:'||v_suffix,
      v_gateway_policy.id,'production',v_reference_namespace,
      'reference_validation','platform','route_reference','received',
      v_correlation_id,'MIGRATION_130',
      jsonb_build_object('api_key','FORBIDDEN'),
      repeat('a',64)
    );

    raise exception 'MIGRATION_130_PLAINTEXT_GUARD_NOT_ENFORCED';
  exception
    when check_violation then
      v_plaintext_guard := true;
  end;

  begin
    insert into public.commercial_secret_reference_gateway_requests (
      request_key,idempotency_key,gateway_policy_id,requested_environment,
      requested_namespace,requested_capability,requested_scope,
      requested_operation,request_status,correlation_id,requested_by,
      request_metadata,request_hash
    ) values (
      'migration_130:endpoint:'||v_suffix,
      'migration_130:endpoint_idem:'||v_suffix,
      v_gateway_policy.id,'production',v_reference_namespace,
      'reference_validation','platform','route_reference','received',
      v_correlation_id,'MIGRATION_130',
      jsonb_build_object('endpoint','forbidden.example'),
      repeat('b',64)
    );

    raise exception 'MIGRATION_130_ENDPOINT_GUARD_NOT_ENFORCED';
  exception
    when check_violation then
      v_endpoint_guard := true;
  end;

  begin
    insert into public.commercial_secret_reference_route_manifests (
      gateway_request_id,gateway_decision_id,manifest_status,route_class,
      backend_code,backend_type,backend_contract_name,
      backend_contract_version,reference_namespace,capability_code,
      binding_priority,dispatch_allowed,generated_by,manifest_hash
    ) values (
      v_request.id,v_decision.id,'held','opaque_reference_metadata',
      v_backend.backend_code,v_backend.backend_type,
      v_backend_version.contract_name,v_backend_version.contract_version,
      v_reference_namespace,'reference_validation',100,true,
      'MIGRATION_130',repeat('c',64)
    );

    raise exception 'MIGRATION_130_ACTIVE_MANIFEST_GUARD_NOT_ENFORCED';
  exception
    when check_violation then
      v_active_manifest_guard := true;
    when foreign_key_violation then
      raise exception 'MIGRATION_130_ACTIVE_MANIFEST_TEST_INVALID_FOREIGN_KEY_PRECEDED_CHECK';
  end;

  begin
    insert into public.commercial_secret_reference_gateway_attempts (
      gateway_request_id,gateway_decision_id,route_manifest_id,
      attempt_number,attempt_status,dispatch_requested,
      recorded_by,reason
    ) values (
      v_request.id,v_decision.id,v_manifest.id,
      99,'blocked',true,'MIGRATION_130','FORBIDDEN_ACTIVE_DISPATCH'
    );

    raise exception 'MIGRATION_130_ACTIVE_ATTEMPT_GUARD_NOT_ENFORCED';
  exception
    when check_violation then
      v_active_attempt_guard := true;
  end;

  if not (
    v_idempotency_conflict_guard
    and v_policy_guard
    and v_candidate_guard
    and v_decision_guard
    and v_manifest_guard
    and v_receipt_guard
    and v_event_guard
    and v_plaintext_guard
    and v_endpoint_guard
    and v_active_manifest_guard
    and v_active_attempt_guard
  ) then
    raise exception 'MIGRATION_130_GUARD_MATRIX_FAILED';
  end if;

  -- ===========================================================================
  -- 11. ECONOMIC/RUNTIME NON-MUTATION
  -- ===========================================================================

  select count(*) into v_purchase_after
  from public.commercial_purchases;

  select count(*) into v_checkout_session_after
  from public.commercial_checkout_sessions;

  select count(*) into v_provider_request_after
  from public.commercial_checkout_provider_requests;

  select count(*) into v_callback_after
  from public.commercial_checkout_callbacks;

  select count(*) into v_reconciliation_after
  from public.commercial_checkout_reconciliation_observations;

  select count(*) into v_wallet_after
  from public.commercial_wallets;

  select count(*) into v_ledger_after
  from public.commercial_ledger;

  select count(*) into v_outbox_after
  from public.commercial_purchase_runtime_outbox;

  if v_purchase_after <> v_purchase_before
     or v_checkout_session_after <> v_checkout_session_before
     or v_provider_request_after <> v_provider_request_before
     or v_callback_after <> v_callback_before
     or v_reconciliation_after <> v_reconciliation_before
     or v_wallet_after <> v_wallet_before
     or v_ledger_after <> v_ledger_before
     or v_outbox_after <> v_outbox_before then
    raise exception
      'MIGRATION_130_ECONOMIC_NON_MUTATION_FAILED purchase_delta=%, checkout_session_delta=%, provider_request_delta=%, callback_delta=%, reconciliation_delta=%, wallet_delta=%, ledger_delta=%, outbox_delta=%',
      v_purchase_after-v_purchase_before,
      v_checkout_session_after-v_checkout_session_before,
      v_provider_request_after-v_provider_request_before,
      v_callback_after-v_callback_before,
      v_reconciliation_after-v_reconciliation_before,
      v_wallet_after-v_wallet_before,
      v_ledger_after-v_ledger_before,
      v_outbox_after-v_outbox_before;
  end if;

  -- ===========================================================================
  -- 12. FINAL CERTIFICATION NOTICE
  -- ===========================================================================

  raise notice
    'MIGRATION_130_CERTIFIED backend_count=%, version_count=%, capability_count=%, validated_capability_count=%, binding_count=%, validated_binding_count=%, request_count=%, idempotency_count=%, candidate_count=%, decision_count=%, manifest_count=%, attempt_count=%, receipt_count=%, event_count=%, replay_count=%, request_status=%, decision_status=%, decision_code=%, manifest_status=%, capability_available=%, idempotency_conflict_guard=%, policy_guard=%, candidate_guard=%, decision_guard=%, manifest_guard=%, receipt_guard=%, event_guard=%, plaintext_guard=%, endpoint_guard=%, active_manifest_guard=%, active_attempt_guard=%, automatic_dispatch_enabled=false, endpoint_discovery_enabled=false, backend_probe_enabled=false, backend_contact_enabled=false, backend_authentication_enabled=false, secret_lookup_enabled=false, secret_resolution_enabled=false, secret_decryption_enabled=false, credential_material_loading_enabled=false, credential_delivery_enabled=false, network_access_enabled=false, opaque_references_only=true, purchase_delta=0, checkout_session_delta=0, provider_request_delta=0, callback_delta=0, reconciliation_delta=0, wallet_delta=0, ledger_delta=0, outbox_delta=0, rollback_required=true',
    v_backend_count,v_version_count,v_capability_count,
    v_validated_capability_count,v_binding_count,v_validated_binding_count,
    v_request_count,v_idempotency_count,v_candidate_count,v_decision_count,
    v_manifest_count,v_attempt_count,v_receipt_count,v_event_count,
    v_read_model.replay_count,v_read_model.request_status,
    v_read_model.decision_status,v_read_model.decision_code,
    v_read_model.manifest_status,v_read_model.capability_available,
    v_idempotency_conflict_guard,v_policy_guard,v_candidate_guard,
    v_decision_guard,v_manifest_guard,v_receipt_guard,v_event_guard,
    v_plaintext_guard,v_endpoint_guard,v_active_manifest_guard,
    v_active_attempt_guard;
end
$$;

rollback;

\echo ''
\echo 'MIGRATION_130_TRANSACTION_ROLLED_BACK'
\echo 'No backend, version, capability, binding, gateway request, idempotency record, candidate, decision, route manifest, attempt, receipt, event, policy change, purchase, checkout, wallet, ledger or outbox mutation was persisted.'
