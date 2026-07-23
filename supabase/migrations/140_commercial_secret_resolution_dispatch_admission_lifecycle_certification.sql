-- =============================================================================
-- FANTAGOL
-- Migration: 140_commercial_secret_resolution_dispatch_admission_lifecycle_certification.sql
-- Milestone: Commercial Secret Resolution Dispatch Admission Lifecycle
--
-- Purpose:
--   Transactionally certify migration 135 through the complete passive chain
--   and the full non-executable permit lifecycle:
--
--     validated backend registry
--       -> accepted reference gateway route
--       -> AUTHORIZED policy/scope decision
--       -> accepted resolution-authorization handoff
--       -> held metadata-only handoff manifest
--       -> blocked operational attempt
--
-- Certification includes:
--   - idempotent replay and conflict rejection;
--   - ten integrity evaluations;
--   - passive manifest invariants;
--   - read-model integrity;
--   - immutable and append-only guards;
--   - plaintext, endpoint and executable-manifest guards;
--   - zero commercial/economic/runtime mutation;
--   - final ROLLBACK.
-- =============================================================================

\set ON_ERROR_STOP on
\timing on

begin;

set local statement_timeout = '120s';
set local lock_timeout = '15s';
set local idle_in_transaction_session_timeout = '180s';

do $$
declare
  v_registry_policy public.commercial_secret_backend_registry_policies;
  v_resolution_policy public.commercial_secret_resolution_policies;
  v_gateway_policy public.commercial_secret_reference_gateway_policies;
  v_authorization_policy public.commercial_secret_reference_authorization_policies;
  v_handoff_policy public.commercial_secret_reference_handoff_policies;

  v_backend public.commercial_secret_backends;
  v_backend_version public.commercial_secret_backend_versions;
  v_binding public.commercial_secret_backend_bindings;

  v_gateway_request public.commercial_secret_reference_gateway_requests;
  v_gateway_decision public.commercial_secret_reference_gateway_decisions;

  v_authorization_request public.commercial_secret_reference_authorization_requests;
  v_authorization_decision public.commercial_secret_reference_authorization_decisions;

  v_handoff_request public.commercial_secret_reference_handoff_requests;
  v_handoff_replay public.commercial_secret_reference_handoff_requests;
  v_handoff_decision public.commercial_secret_reference_handoff_decisions;
  v_handoff_manifest public.commercial_secret_reference_handoff_manifests;
  v_handoff_attempt public.commercial_secret_reference_handoff_attempts;
  v_read public.commercial_secret_reference_handoff_read_model;

  v_permit_policy public.commercial_secret_resolution_execution_permit_policies;
  v_permit_request public.commercial_secret_resolution_execution_permit_requests;
  v_permit_replay public.commercial_secret_resolution_execution_permit_requests;
  v_permit_decision public.commercial_secret_resolution_execution_permit_decisions;
  v_execution_permit public.commercial_secret_resolution_execution_permits;
  v_permit_attempt public.commercial_secret_resolution_execution_permit_attempts;
  v_permit_revocation public.commercial_secret_resolution_execution_permit_revocations;
  v_permit_read public.commercial_secret_resolution_execution_permit_read_model;

  v_envelope_policy public.commercial_secret_resolution_dispatch_envelope_policies;
  v_envelope_request public.commercial_secret_resolution_dispatch_envelope_requests;
  v_envelope_replay public.commercial_secret_resolution_dispatch_envelope_requests;
  v_envelope_decision public.commercial_secret_resolution_dispatch_envelope_decisions;
  v_dispatch_envelope public.commercial_secret_resolution_dispatch_envelopes;
  v_envelope_attempt public.commercial_secret_resolution_dispatch_envelope_attempts;
  v_envelope_cancellation public.commercial_secret_resolution_dispatch_envelope_cancellations;
  v_envelope_read public.commercial_secret_resolution_dispatch_envelope_read_model;

  v_admission_policy public.commercial_secret_resolution_dispatch_admission_policies;
  v_admission_request public.commercial_secret_resolution_dispatch_admission_requests;
  v_admission_replay public.commercial_secret_resolution_dispatch_admission_requests;
  v_admission_decision public.commercial_secret_resolution_dispatch_admission_decisions;
  v_admission_ticket public.commercial_secret_resolution_dispatch_admission_tickets;
  v_admission_attempt public.commercial_secret_resolution_dispatch_admission_attempts;
  v_admission_cancellation public.commercial_secret_resolution_dispatch_admission_cancellations;
  v_admission_read public.commercial_secret_resolution_dispatch_admission_read_model;

  v_suffix text := lower(substr(replace(gen_random_uuid()::text,'-',''),1,12));
  v_backend_code text;
  v_backend_name text;
  v_namespace text;
  v_binding_key text;
  v_corr uuid := gen_random_uuid();
  v_cause uuid := gen_random_uuid();

  v_reference_fingerprint text :=
    encode(extensions.digest(gen_random_uuid()::text,'sha256'),'hex');
  v_contract_hash text :=
    encode(extensions.digest(gen_random_uuid()::text,'sha256'),'hex');
  v_reference_schema_hash text :=
    encode(extensions.digest(gen_random_uuid()::text,'sha256'),'hex');

  v_idempotency_conflict_guard boolean := false;
  v_policy_guard boolean := false;
  v_evaluation_guard boolean := false;
  v_decision_guard boolean := false;
  v_manifest_guard boolean := false;
  v_attempt_guard boolean := false;
  v_receipt_guard boolean := false;
  v_event_guard boolean := false;
  v_plaintext_guard boolean := false;
  v_endpoint_guard boolean := false;
  v_executable_manifest_guard boolean := false;

  v_permit_idempotency_conflict_guard boolean := false;
  v_permit_policy_guard boolean := false;
  v_permit_evaluation_guard boolean := false;
  v_permit_decision_guard boolean := false;
  v_execution_permit_guard boolean := false;
  v_permit_revocation_guard boolean := false;
  v_permit_attempt_guard boolean := false;
  v_permit_receipt_guard boolean := false;
  v_permit_event_guard boolean := false;
  v_permit_plaintext_guard boolean := false;
  v_permit_endpoint_guard boolean := false;
  v_active_policy_guard boolean := false;

  v_envelope_idempotency_conflict_guard boolean := false;
  v_envelope_policy_guard boolean := false;
  v_envelope_evaluation_guard boolean := false;
  v_envelope_decision_guard boolean := false;
  v_dispatch_envelope_guard boolean := false;
  v_envelope_cancellation_guard boolean := false;
  v_envelope_attempt_guard boolean := false;
  v_envelope_receipt_guard boolean := false;
  v_envelope_event_guard boolean := false;
  v_envelope_plaintext_guard boolean := false;
  v_envelope_endpoint_guard boolean := false;
  v_executable_envelope_guard boolean := false;

  v_admission_idempotency_conflict_guard boolean := false;
  v_admission_policy_guard boolean := false;
  v_admission_evaluation_guard boolean := false;
  v_admission_decision_guard boolean := false;
  v_admission_ticket_guard boolean := false;
  v_admission_cancellation_guard boolean := false;
  v_admission_attempt_guard boolean := false;
  v_admission_receipt_guard boolean := false;
  v_admission_event_guard boolean := false;
  v_admission_plaintext_guard boolean := false;
  v_admission_endpoint_guard boolean := false;
  v_executable_ticket_guard boolean := false;

  v_probe_handoff_request_id uuid;
  v_probe_handoff_decision_id uuid;

  v_backend_count bigint;
  v_version_count bigint;
  v_capability_count bigint;
  v_binding_count bigint;
  v_gateway_request_count bigint;
  v_gateway_decision_count bigint;
  v_authorization_request_count bigint;
  v_authorization_evaluation_count bigint;
  v_authorization_decision_count bigint;
  v_handoff_request_count bigint;
  v_handoff_idempotency_count bigint;
  v_handoff_evaluation_count bigint;
  v_handoff_decision_count bigint;
  v_handoff_manifest_count bigint;
  v_handoff_attempt_count bigint;
  v_handoff_receipt_count bigint;
  v_handoff_event_count bigint;
  v_handoff_replay_count bigint;

  v_permit_request_count bigint;
  v_permit_idempotency_count bigint;
  v_permit_evaluation_count bigint;
  v_permit_decision_count bigint;
  v_execution_permit_count bigint;
  v_permit_revocation_count bigint;
  v_permit_attempt_count bigint;
  v_permit_receipt_count bigint;
  v_permit_event_count bigint;
  v_permit_replay_count bigint;

  v_envelope_request_count bigint;
  v_envelope_idempotency_count bigint;
  v_envelope_evaluation_count bigint;
  v_envelope_decision_count bigint;
  v_dispatch_envelope_count bigint;
  v_envelope_cancellation_count bigint;
  v_envelope_attempt_count bigint;
  v_envelope_receipt_count bigint;
  v_envelope_event_count bigint;
  v_envelope_replay_count bigint;

  v_probe_envelope_request_id uuid;
  v_probe_envelope_decision_id uuid;

  v_admission_request_count bigint;
  v_admission_idempotency_count bigint;
  v_admission_evaluation_count bigint;
  v_admission_decision_count bigint;
  v_admission_ticket_count bigint;
  v_admission_cancellation_count bigint;
  v_admission_attempt_count bigint;
  v_admission_receipt_count bigint;
  v_admission_event_count bigint;
  v_admission_replay_count bigint;

  v_probe_admission_request_id uuid;
  v_probe_admission_decision_id uuid;

  v_purchase_before bigint;
  v_checkout_before bigint;
  v_provider_request_before bigint;
  v_callback_before bigint;
  v_reconciliation_before bigint;
  v_wallet_before bigint;
  v_ledger_before bigint;
  v_outbox_before bigint;

  v_purchase_after bigint;
  v_checkout_after bigint;
  v_provider_request_after bigint;
  v_callback_after bigint;
  v_reconciliation_after bigint;
  v_wallet_after bigint;
  v_ledger_after bigint;
  v_outbox_after bigint;
begin
  -- ===========================================================================
  -- 1. DEPENDENCIES AND POLICY POSTURE
  -- ===========================================================================

  if to_regclass('public.commercial_secret_reference_handoff_policies') is null
     or to_regclass('public.commercial_secret_reference_handoff_requests') is null
     or to_regclass('public.commercial_secret_reference_handoff_idempotency') is null
     or to_regclass('public.commercial_secret_reference_handoff_evaluations') is null
     or to_regclass('public.commercial_secret_reference_handoff_decisions') is null
     or to_regclass('public.commercial_secret_reference_handoff_manifests') is null
     or to_regclass('public.commercial_secret_reference_handoff_attempts') is null
     or to_regclass('public.commercial_secret_reference_handoff_receipts') is null
     or to_regclass('public.commercial_secret_reference_handoff_events') is null
     or to_regclass('public.commercial_secret_reference_handoff_read_model') is null then
    raise exception 'MIGRATION_140_REQUIRES_MIGRATION_133_OBJECTS';
  end if;

  if to_regclass('public.commercial_secret_resolution_execution_permit_policies') is null
     or to_regclass('public.commercial_secret_resolution_execution_permit_requests') is null
     or to_regclass('public.commercial_secret_resolution_execution_permit_idempotency') is null
     or to_regclass('public.commercial_secret_resolution_execution_permit_evaluations') is null
     or to_regclass('public.commercial_secret_resolution_execution_permit_decisions') is null
     or to_regclass('public.commercial_secret_resolution_execution_permits') is null
     or to_regclass('public.commercial_secret_resolution_execution_permit_revocations') is null
     or to_regclass('public.commercial_secret_resolution_execution_permit_attempts') is null
     or to_regclass('public.commercial_secret_resolution_execution_permit_receipts') is null
     or to_regclass('public.commercial_secret_resolution_execution_permit_events') is null
     or to_regclass('public.commercial_secret_resolution_execution_permit_read_model') is null then
    raise exception 'MIGRATION_140_REQUIRES_MIGRATION_135_OBJECTS';
  end if;

  if to_regprocedure(
       'public.enqueue_commercial_secret_reference_handoff_request(text,text,uuid,uuid,text,text,text,text,text,text,uuid,uuid,jsonb)'
     ) is null
     or to_regprocedure(
       'public.evaluate_commercial_secret_reference_handoff_request(uuid,text)'
     ) is null
     or to_regprocedure(
       'public.build_commercial_secret_reference_handoff_manifest(uuid,text,jsonb)'
     ) is null
     or to_regprocedure(
       'public.record_blocked_secret_reference_handoff_attempt(uuid,text,text,jsonb)'
     ) is null then
    raise exception 'MIGRATION_140_REQUIRES_MIGRATION_133_FUNCTIONS';
  end if;

  if to_regclass('public.commercial_secret_resolution_dispatch_envelope_policies') is null
     or to_regclass('public.commercial_secret_resolution_dispatch_envelope_requests') is null
     or to_regclass('public.commercial_secret_resolution_dispatch_envelope_idempotency') is null
     or to_regclass('public.commercial_secret_resolution_dispatch_envelope_evaluations') is null
     or to_regclass('public.commercial_secret_resolution_dispatch_envelope_decisions') is null
     or to_regclass('public.commercial_secret_resolution_dispatch_envelopes') is null
     or to_regclass('public.commercial_secret_resolution_dispatch_envelope_cancellations') is null
     or to_regclass('public.commercial_secret_resolution_dispatch_envelope_attempts') is null
     or to_regclass('public.commercial_secret_resolution_dispatch_envelope_receipts') is null
     or to_regclass('public.commercial_secret_resolution_dispatch_envelope_events') is null
     or to_regclass('public.commercial_secret_resolution_dispatch_envelope_read_model') is null then
    raise exception 'MIGRATION_140_REQUIRES_MIGRATION_137_OBJECTS';
  end if;

  if to_regprocedure(
       'public.enqueue_commercial_secret_resolution_dispatch_envelope_request(text,text,uuid,text,text,text,text,text,integer,text,uuid,uuid,jsonb)'
     ) is null
     or to_regprocedure(
       'public.evaluate_commercial_secret_resolution_dispatch_envelope_request(uuid,text)'
     ) is null
     or to_regprocedure(
       'public.issue_commercial_secret_resolution_dispatch_envelope(uuid,text,jsonb)'
     ) is null
     or to_regprocedure(
       'public.cancel_commercial_secret_resolution_dispatch_envelope(uuid,text,text,text,text,uuid,uuid,jsonb)'
     ) is null
     or to_regprocedure(
       'public.record_blocked_secret_resolution_dispatch_envelope_attempt(uuid,text,text,jsonb)'
     ) is null then
    raise exception 'MIGRATION_140_REQUIRES_MIGRATION_137_FUNCTIONS';
  end if;

  if to_regclass('public.commercial_secret_resolution_dispatch_admission_policies') is null
     or to_regclass('public.commercial_secret_resolution_dispatch_admission_requests') is null
     or to_regclass('public.commercial_secret_resolution_dispatch_admission_idempotency') is null
     or to_regclass('public.commercial_secret_resolution_dispatch_admission_evaluations') is null
     or to_regclass('public.commercial_secret_resolution_dispatch_admission_decisions') is null
     or to_regclass('public.commercial_secret_resolution_dispatch_admission_tickets') is null
     or to_regclass('public.commercial_secret_resolution_dispatch_admission_cancellations') is null
     or to_regclass('public.commercial_secret_resolution_dispatch_admission_attempts') is null
     or to_regclass('public.commercial_secret_resolution_dispatch_admission_receipts') is null
     or to_regclass('public.commercial_secret_resolution_dispatch_admission_events') is null
     or to_regclass('public.commercial_secret_resolution_dispatch_admission_read_model') is null then
    raise exception 'MIGRATION_140_REQUIRES_MIGRATION_139_OBJECTS';
  end if;

  if to_regprocedure(
       'public.enqueue_commercial_secret_resolution_dispatch_admission_request(text,text,uuid,text,text,text,text,text,integer,text,uuid,uuid,jsonb)'
     ) is null
     or to_regprocedure(
       'public.evaluate_commercial_secret_resolution_dispatch_admission_request(uuid,text)'
     ) is null
     or to_regprocedure(
       'public.issue_commercial_secret_resolution_dispatch_admission_ticket(uuid,text,jsonb)'
     ) is null
     or to_regprocedure(
       'public.cancel_commercial_secret_resolution_dispatch_admission_ticket(uuid,text,text,text,text,uuid,uuid,jsonb)'
     ) is null
     or to_regprocedure(
       'public.record_blocked_secret_resolution_dispatch_admission_attempt(uuid,text,text,jsonb)'
     ) is null then
    raise exception 'MIGRATION_140_REQUIRES_MIGRATION_139_FUNCTIONS';
  end if;

  select * into strict v_registry_policy
  from public.commercial_secret_backend_registry_policies
  where policy_code='commercial:provider_secret_backend_registry:v1'
    and environment='production'
    and policy_status='approved';

  select * into strict v_resolution_policy
  from public.commercial_secret_resolution_policies
  where policy_code='commercial:provider_secret_resolution:v1'
    and environment='production'
    and policy_status='approved';

  select * into strict v_gateway_policy
  from public.commercial_secret_reference_gateway_policies
  where policy_code='commercial:provider_secret_reference_gateway:v1'
    and environment='production'
    and policy_status='approved';

  select * into strict v_authorization_policy
  from public.commercial_secret_reference_authorization_policies
  where policy_code='commercial:secret_reference_authorization:v1'
    and environment='production'
    and policy_status='approved';

  select * into strict v_handoff_policy
  from public.commercial_secret_reference_handoff_policies
  where policy_code='commercial:secret_reference_resolution_handoff:v1'
    and environment='production'
    and policy_status='approved';

  select * into strict v_permit_policy
  from public.commercial_secret_resolution_execution_permit_policies
  where policy_code='commercial:secret_resolution_execution_permit:v1'
    and environment='production'
    and policy_status='approved';

  select * into strict v_envelope_policy
  from public.commercial_secret_resolution_dispatch_envelope_policies
  where policy_code='commercial:secret_resolution_dispatch_envelope:v1'
    and environment='production'
    and policy_status='approved';

  if v_envelope_policy.automatic_dispatch_enabled
     or v_envelope_policy.dispatch_enabled
     or v_envelope_policy.queue_publication_enabled
     or v_envelope_policy.worker_claim_enabled
     or v_envelope_policy.permit_execution_enabled
     or v_envelope_policy.endpoint_discovery_enabled
     or v_envelope_policy.backend_probe_enabled
     or v_envelope_policy.backend_contact_enabled
     or v_envelope_policy.backend_authentication_enabled
     or v_envelope_policy.secret_lookup_enabled
     or v_envelope_policy.secret_resolution_enabled
     or v_envelope_policy.secret_decryption_enabled
     or v_envelope_policy.credential_material_loading_enabled
     or v_envelope_policy.credential_delivery_enabled
     or v_envelope_policy.network_access_enabled
     or not v_envelope_policy.opaque_references_only
     or not v_envelope_policy.plaintext_storage_forbidden
     or not v_envelope_policy.metadata_only
     or not v_envelope_policy.executable_envelopes_forbidden then
    raise exception 'MIGRATION_140_ENVELOPE_POLICY_POSTURE_FAILED';
  end if;

  select * into strict v_admission_policy
  from public.commercial_secret_resolution_dispatch_admission_policies
  where policy_code='commercial:secret_resolution_dispatch_admission:v1'
    and environment='production'
    and policy_status='approved';

  if v_admission_policy.automatic_publication_enabled
     or v_admission_policy.queue_publication_enabled
     or v_admission_policy.runtime_job_creation_enabled
     or v_admission_policy.worker_lease_enabled
     or v_admission_policy.worker_claim_enabled
     or v_admission_policy.dispatch_enabled
     or v_admission_policy.envelope_execution_enabled
     or v_admission_policy.permit_execution_enabled
     or v_admission_policy.endpoint_discovery_enabled
     or v_admission_policy.backend_probe_enabled
     or v_admission_policy.backend_contact_enabled
     or v_admission_policy.backend_authentication_enabled
     or v_admission_policy.secret_lookup_enabled
     or v_admission_policy.secret_resolution_enabled
     or v_admission_policy.secret_decryption_enabled
     or v_admission_policy.credential_material_loading_enabled
     or v_admission_policy.credential_delivery_enabled
     or v_admission_policy.network_access_enabled
     or not v_admission_policy.opaque_references_only
     or not v_admission_policy.plaintext_storage_forbidden
     or not v_admission_policy.metadata_only
     or not v_admission_policy.executable_tickets_forbidden then
    raise exception 'MIGRATION_140_ADMISSION_POLICY_POSTURE_FAILED';
  end if;

  if not (
    v_handoff_policy.intake_enabled
    and v_handoff_policy.authorization_verification_enabled
    and v_handoff_policy.route_integrity_verification_enabled
    and v_handoff_policy.scope_integrity_verification_enabled
    and v_handoff_policy.capability_integrity_verification_enabled
    and v_handoff_policy.backend_binding_integrity_enabled
    and v_handoff_policy.manifest_generation_enabled
    and v_handoff_policy.decision_recording_enabled
  ) then
    raise exception 'MIGRATION_140_HANDOFF_CAPABILITY_MATRIX_DISABLED';
  end if;

  if v_handoff_policy.automatic_dispatch_enabled
     or v_handoff_policy.activation_enabled
     or v_handoff_policy.endpoint_discovery_enabled
     or v_handoff_policy.backend_probe_enabled
     or v_handoff_policy.backend_contact_enabled
     or v_handoff_policy.backend_authentication_enabled
     or v_handoff_policy.secret_lookup_enabled
     or v_handoff_policy.secret_resolution_enabled
     or v_handoff_policy.secret_decryption_enabled
     or v_handoff_policy.credential_material_loading_enabled
     or v_handoff_policy.credential_delivery_enabled
     or v_handoff_policy.network_access_enabled then
    raise exception 'MIGRATION_140_UNSAFE_HANDOFF_POLICY';
  end if;

  -- ===========================================================================
  -- 2. ECONOMIC/RUNTIME BASELINES
  -- ===========================================================================

  select count(*) into v_purchase_before
  from public.commercial_purchases;

  select count(*) into v_checkout_before
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

  v_backend_code := 'migration_140_backend_' || v_suffix;
  v_backend_name := 'Migration 136 Passive Backend ' || upper(v_suffix);
  v_namespace := 'migration_140:opaque:' || v_suffix;
  v_binding_key := 'migration_140:binding:' || v_suffix;

  v_backend := public.register_commercial_secret_backend(
    v_backend_code,
    v_backend_name,
    'development_stub',
    'production',
    'platform',
    null,
    null,
    'unspecified',
    v_namespace,
    v_reference_fingerprint,
    'MIGRATION_140',
    v_corr,
    jsonb_build_object(
      'temporary',true,
      'certification','MIGRATION_140',
      'opaque_references_only',true
    )
  );

  v_backend_version := public.register_commercial_secret_backend_version(
    v_backend.id,
    1,
    'FantaGol Handoff Lifecycle Contract',
    '1.0.0',
    v_contract_hash,
    v_reference_schema_hash,
    true,true,true,true,
    'MIGRATION_140',
    v_corr,
    jsonb_build_object(
      'temporary',true,
      'passive_only',true,
      'metadata_only',true
    )
  );

  perform public.register_commercial_secret_backend_capability(
    v_backend_version.id,
    'reference_validation',
    'reference_validation',
    'MIGRATION_140',
    v_corr,
    '{"temporary":true,"offline_only":true}'::jsonb
  );

  perform public.register_commercial_secret_backend_capability(
    v_backend_version.id,
    'versioned_references',
    'version_metadata',
    'MIGRATION_140',
    v_corr,
    '{"temporary":true,"offline_only":true}'::jsonb
  );

  perform public.register_commercial_secret_backend_capability(
    v_backend_version.id,
    'rotation_metadata',
    'rotation_metadata',
    'MIGRATION_140',
    v_corr,
    '{"temporary":true,"offline_only":true}'::jsonb
  );

  perform public.register_commercial_secret_backend_capability(
    v_backend_version.id,
    'expiry_metadata',
    'expiry_metadata',
    'MIGRATION_140',
    v_corr,
    '{"temporary":true,"offline_only":true}'::jsonb
  );

  perform public.register_commercial_secret_backend_capability(
    v_backend_version.id,
    'scope_metadata',
    'scope_metadata',
    'MIGRATION_140',
    v_corr,
    '{"temporary":true,"offline_only":true}'::jsonb
  );

  v_backend_version := public.validate_commercial_secret_backend_version(
    v_backend_version.id,
    'MIGRATION_140',
    v_corr
  );

  select * into strict v_backend
  from public.commercial_secret_backends
  where id=v_backend.id;

  v_binding := public.register_commercial_secret_backend_binding(
    v_binding_key,
    v_backend.id,
    v_backend_version.id,
    null,
    v_resolution_policy.id,
    'platform',
    100,
    v_namespace,
    'MIGRATION_140',
    v_corr,
    jsonb_build_object(
      'temporary',true,
      'passive_only',true,
      'metadata_only',true
    )
  );

  v_binding := public.validate_commercial_secret_backend_binding(
    v_binding.id,
    'MIGRATION_140',
    v_corr
  );

  -- ===========================================================================
  -- 4. ACCEPTED REFERENCE GATEWAY ROUTE
  -- ===========================================================================

  v_gateway_request :=
    public.enqueue_commercial_secret_reference_gateway_request(
      'migration_140:gateway_request:'||v_suffix,
      'migration_140:gateway_idempotency:'||v_suffix,
      null,
      null,
      'production',
      v_namespace,
      'reference_validation',
      'platform',
      'MIGRATION_140',
      v_corr,
      v_cause,
      jsonb_build_object(
        'temporary',true,
        'opaque_references_only',true,
        'metadata_only',true
      )
    );

  v_gateway_decision :=
    public.evaluate_commercial_secret_reference_gateway_request(
      v_gateway_request.id,
      'MIGRATION_140'
    );

  if v_gateway_decision.decision_status<>'accepted'
     or v_gateway_decision.decision_code<>'ROUTE_METADATA_ACCEPTED'
     or v_gateway_decision.selected_backend_binding_id<>v_binding.id
     or v_gateway_decision.selected_backend_id<>v_backend.id
     or v_gateway_decision.selected_backend_version_id<>v_backend_version.id
     or not v_gateway_decision.capability_available then
    raise exception 'MIGRATION_140_GATEWAY_PREREQUISITE_FAILED';
  end if;

  -- ===========================================================================
  -- 5. AUTHORIZED POLICY/SCOPE DECISION
  -- ===========================================================================

  v_authorization_request :=
    public.enqueue_commercial_secret_reference_authorization_request(
      'migration_140:authorization:'||v_suffix,
      'migration_140:authorization_idempotency:'||v_suffix,
      v_gateway_request.id,
      v_gateway_decision.id,
      'platform',
      'platform',
      v_namespace,
      'reference_validation',
      'MIGRATION_140',
      v_corr,
      v_cause,
      jsonb_build_object(
        'temporary',true,
        'scenario','AUTHORIZED',
        'opaque_references_only',true
      )
    );

  v_authorization_decision :=
    public.evaluate_commercial_secret_reference_authorization_request(
      v_authorization_request.id,
      'MIGRATION_140'
    );

  if v_authorization_decision.decision_status<>'authorized'
     or v_authorization_decision.decision_code<>'AUTHORIZED'
     or not v_authorization_decision.authorized
     or v_authorization_decision.selected_backend_binding_id<>v_binding.id
     or v_authorization_decision.selected_backend_id<>v_backend.id
     or v_authorization_decision.selected_backend_version_id<>v_backend_version.id
     or v_authorization_decision.resolved_scope_type<>'platform'
     or v_authorization_decision.resolved_scope_key<>'platform'
     or v_authorization_decision.resolved_namespace<>v_namespace
     or v_authorization_decision.resolved_capability<>'reference_validation' then
    raise exception 'MIGRATION_140_AUTHORIZATION_PREREQUISITE_FAILED';
  end if;

  -- ===========================================================================
  -- 6. HANDOFF INTAKE + IDEMPOTENT REPLAY
  -- ===========================================================================

  v_handoff_request :=
    public.enqueue_commercial_secret_reference_handoff_request(
      'migration_140:handoff:'||v_suffix,
      'migration_140:handoff_idempotency:'||v_suffix,
      v_authorization_request.id,
      v_authorization_decision.id,
      'production',
      'platform',
      'platform',
      v_namespace,
      'reference_validation',
      'MIGRATION_140',
      v_corr,
      v_cause,
      jsonb_build_object(
        'temporary',true,
        'passive_handoff_only',true,
        'opaque_references_only',true,
        'metadata_only',true
      )
    );

  v_handoff_replay :=
    public.enqueue_commercial_secret_reference_handoff_request(
      'migration_140:handoff:'||v_suffix,
      'migration_140:handoff_idempotency:'||v_suffix,
      v_authorization_request.id,
      v_authorization_decision.id,
      'production',
      'platform',
      'platform',
      v_namespace,
      'reference_validation',
      'MIGRATION_140',
      v_corr,
      v_cause,
      jsonb_build_object(
        'temporary',true,
        'passive_handoff_only',true,
        'opaque_references_only',true,
        'metadata_only',true
      )
    );

  if v_handoff_replay.id<>v_handoff_request.id then
    raise exception 'MIGRATION_140_IDEMPOTENT_REPLAY_CREATED_DUPLICATE';
  end if;

  begin
    perform public.enqueue_commercial_secret_reference_handoff_request(
      'migration_140:handoff:'||v_suffix,
      'migration_140:handoff_idempotency:'||v_suffix,
      v_authorization_request.id,
      v_authorization_decision.id,
      'production',
      'platform',
      'platform',
      v_namespace,
      'scope_metadata',
      'MIGRATION_140',
      v_corr,
      v_cause,
      jsonb_build_object(
        'temporary',true,
        'scenario','IDEMPOTENCY_CONFLICT'
      )
    );

    raise exception 'MIGRATION_140_IDEMPOTENCY_CONFLICT_NOT_ENFORCED';
  exception
    when others then
      if sqlerrm='COMMERCIAL_SECRET_REFERENCE_HANDOFF_IDEMPOTENCY_CONFLICT' then
        v_idempotency_conflict_guard:=true;
      else
        raise;
      end if;
  end;

  -- ===========================================================================
  -- 7. ACCEPTED HANDOFF DECISION
  -- ===========================================================================

  v_handoff_decision :=
    public.evaluate_commercial_secret_reference_handoff_request(
      v_handoff_request.id,
      'MIGRATION_140'
    );

  if v_handoff_decision.decision_status<>'accepted'
     or v_handoff_decision.decision_code<>'HANDOFF_ACCEPTED'
     or not v_handoff_decision.accepted
     or v_handoff_decision.authorization_decision_id<>v_authorization_decision.id
     or v_handoff_decision.selected_backend_binding_id<>v_binding.id
     or v_handoff_decision.selected_backend_id<>v_backend.id
     or v_handoff_decision.selected_backend_version_id<>v_backend_version.id
     or v_handoff_decision.resolved_environment<>'production'
     or v_handoff_decision.resolved_scope_type<>'platform'
     or v_handoff_decision.resolved_scope_key<>'platform'
     or v_handoff_decision.resolved_namespace<>v_namespace
     or v_handoff_decision.resolved_capability<>'reference_validation' then
    raise exception 'MIGRATION_140_HANDOFF_ACCEPTED_PATH_FAILED';
  end if;

  if v_handoff_decision.dispatch_allowed
     or v_handoff_decision.activation_allowed
     or v_handoff_decision.endpoint_discovery_allowed
     or v_handoff_decision.backend_contact_allowed
     or v_handoff_decision.authentication_allowed
     or v_handoff_decision.secret_lookup_allowed
     or v_handoff_decision.secret_resolution_allowed
     or v_handoff_decision.decryption_allowed
     or v_handoff_decision.material_loading_allowed
     or v_handoff_decision.delivery_allowed
     or v_handoff_decision.network_access_allowed then
    raise exception 'MIGRATION_140_HANDOFF_DECISION_NOT_PASSIVE';
  end if;

  -- ===========================================================================
  -- 8. HELD METADATA-ONLY MANIFEST
  -- ===========================================================================

  v_handoff_manifest :=
    public.build_commercial_secret_reference_handoff_manifest(
      v_handoff_request.id,
      'MIGRATION_140',
      jsonb_build_object(
        'temporary',true,
        'opaque_reference_contract',true,
        'metadata_only',true,
        'execution_forbidden',true
      )
    );

  if v_handoff_manifest.manifest_status<>'held'
     or not v_handoff_manifest.opaque_reference_contract
     or not v_handoff_manifest.metadata_only
     or v_handoff_manifest.executable
     or v_handoff_manifest.dispatch_allowed
     or v_handoff_manifest.activation_allowed
     or v_handoff_manifest.backend_contact_allowed
     or v_handoff_manifest.secret_resolution_allowed
     or v_handoff_manifest.network_access_allowed
     or v_handoff_manifest.handoff_request_id<>v_handoff_request.id
     or v_handoff_manifest.handoff_decision_id<>v_handoff_decision.id
     or v_handoff_manifest.authorization_request_id<>v_authorization_request.id
     or v_handoff_manifest.authorization_decision_id<>v_authorization_decision.id
     or v_handoff_manifest.selected_backend_binding_id<>v_binding.id
     or v_handoff_manifest.selected_backend_id<>v_backend.id
     or v_handoff_manifest.selected_backend_version_id<>v_backend_version.id
     or v_handoff_manifest.environment<>'production'
     or v_handoff_manifest.scope_type<>'platform'
     or v_handoff_manifest.scope_key<>'platform'
     or v_handoff_manifest.namespace_code<>v_namespace
     or v_handoff_manifest.capability_code<>'reference_validation' then
    raise exception 'MIGRATION_140_HANDOFF_MANIFEST_FAILED';
  end if;

  -- ===========================================================================
  -- 9. BLOCKED OPERATIONAL ATTEMPT
  -- ===========================================================================

  v_handoff_attempt :=
    public.record_blocked_secret_reference_handoff_attempt(
      v_handoff_request.id,
      'SECRET_RESOLUTION',
      'MIGRATION_140',
      jsonb_build_object(
        'temporary',true,
        'certification_probe',true,
        'expected_result','blocked'
      )
    );

  if v_handoff_attempt.attempt_type<>'SECRET_RESOLUTION'
     or v_handoff_attempt.attempt_status<>'blocked'
     or v_handoff_attempt.block_code<>'PASSIVE_HANDOFF_EXECUTION_FORBIDDEN'
     or v_handoff_attempt.handoff_request_id<>v_handoff_request.id
     or v_handoff_attempt.handoff_decision_id<>v_handoff_decision.id
     or v_handoff_attempt.handoff_manifest_id<>v_handoff_manifest.id then
    raise exception 'MIGRATION_140_BLOCKED_ATTEMPT_FAILED';
  end if;

  -- ===========================================================================
  -- 10. NON-EXECUTABLE EXECUTION-PERMIT LIFECYCLE
  -- ===========================================================================

  v_permit_request :=
    public.enqueue_commercial_secret_resolution_execution_permit_request(
      'migration_140:permit:'||v_suffix,
      'migration_140:permit_idempotency:'||v_suffix,
      v_handoff_request.id,
      v_handoff_decision.id,
      v_handoff_manifest.id,
      'production',
      'platform',
      'platform',
      v_namespace,
      'reference_validation',
      3,
      'MIGRATION_140',
      v_corr,
      v_cause,
      jsonb_build_object(
        'temporary',true,
        'certification','MIGRATION_140',
        'metadata_only',true,
        'executable',false
      )
    );

  v_permit_replay :=
    public.enqueue_commercial_secret_resolution_execution_permit_request(
      'migration_140:permit:'||v_suffix,
      'migration_140:permit_idempotency:'||v_suffix,
      v_handoff_request.id,
      v_handoff_decision.id,
      v_handoff_manifest.id,
      'production',
      'platform',
      'platform',
      v_namespace,
      'reference_validation',
      3,
      'MIGRATION_140',
      v_corr,
      v_cause,
      jsonb_build_object(
        'temporary',true,
        'certification','MIGRATION_140',
        'metadata_only',true,
        'executable',false
      )
    );

  if v_permit_replay.id<>v_permit_request.id then
    raise exception 'MIGRATION_140_PERMIT_REPLAY_CREATED_DUPLICATE';
  end if;

  begin
    perform public.enqueue_commercial_secret_resolution_execution_permit_request(
      'migration_140:permit:'||v_suffix,
      'migration_140:permit_idempotency:'||v_suffix,
      v_handoff_request.id,
      v_handoff_decision.id,
      v_handoff_manifest.id,
      'production',
      'platform',
      'platform',
      v_namespace,
      'reference_validation',
      4,
      'MIGRATION_140',
      v_corr,
      v_cause,
      '{"temporary":true,"scenario":"IDEMPOTENCY_CONFLICT"}'::jsonb
    );

    raise exception 'MIGRATION_140_PERMIT_IDEMPOTENCY_CONFLICT_NOT_ENFORCED';
  exception
    when others then
      if sqlerrm='COMMERCIAL_SECRET_RESOLUTION_EXECUTION_PERMIT_IDEMPOTENCY_CONFLICT' then
        v_permit_idempotency_conflict_guard:=true;
      else
        raise;
      end if;
  end;

  v_permit_decision :=
    public.evaluate_commercial_secret_resolution_execution_permit_request(
      v_permit_request.id,
      'MIGRATION_140'
    );

  if v_permit_decision.decision_status<>'approved'
     or v_permit_decision.decision_code<>'PERMIT_METADATA_APPROVED'
     or not v_permit_decision.approved
     or v_permit_decision.handoff_manifest_id<>v_handoff_manifest.id
     or v_permit_decision.selected_backend_binding_id<>v_binding.id
     or v_permit_decision.selected_backend_id<>v_backend.id
     or v_permit_decision.selected_backend_version_id<>v_backend_version.id
     or v_permit_decision.resolved_environment<>'production'
     or v_permit_decision.resolved_scope_type<>'platform'
     or v_permit_decision.resolved_scope_key<>'platform'
     or v_permit_decision.resolved_namespace<>v_namespace
     or v_permit_decision.resolved_capability<>'reference_validation'
     or v_permit_decision.resolved_operation<>'secret_resolution'
     or v_permit_decision.granted_lifetime_seconds<>3
     or v_permit_decision.not_before is null
     or v_permit_decision.expires_at is null
     or v_permit_decision.expires_at<=v_permit_decision.not_before then
    raise exception 'MIGRATION_140_PERMIT_DECISION_FAILED';
  end if;

  if v_permit_decision.permit_execution_allowed
     or v_permit_decision.dispatch_allowed
     or v_permit_decision.endpoint_discovery_allowed
     or v_permit_decision.backend_contact_allowed
     or v_permit_decision.authentication_allowed
     or v_permit_decision.secret_lookup_allowed
     or v_permit_decision.secret_resolution_allowed
     or v_permit_decision.decryption_allowed
     or v_permit_decision.material_loading_allowed
     or v_permit_decision.delivery_allowed
     or v_permit_decision.network_access_allowed then
    raise exception 'MIGRATION_140_PERMIT_DECISION_NOT_PASSIVE';
  end if;

  v_execution_permit :=
    public.issue_commercial_secret_resolution_execution_permit(
      v_permit_request.id,
      'MIGRATION_140',
      jsonb_build_object(
        'temporary',true,
        'certification','MIGRATION_140',
        'metadata_only',true,
        'executable',false,
        'bearer_credential',false
      )
    );

  if v_execution_permit.permit_status<>'issued'
     or v_execution_permit.permit_request_id<>v_permit_request.id
     or v_execution_permit.permit_decision_id<>v_permit_decision.id
     or v_execution_permit.handoff_request_id<>v_handoff_request.id
     or v_execution_permit.handoff_decision_id<>v_handoff_decision.id
     or v_execution_permit.handoff_manifest_id<>v_handoff_manifest.id
     or v_execution_permit.authorization_request_id<>v_authorization_request.id
     or v_execution_permit.authorization_decision_id<>v_authorization_decision.id
     or v_execution_permit.selected_backend_binding_id<>v_binding.id
     or v_execution_permit.selected_backend_id<>v_backend.id
     or v_execution_permit.selected_backend_version_id<>v_backend_version.id
     or v_execution_permit.environment<>'production'
     or v_execution_permit.scope_type<>'platform'
     or v_execution_permit.scope_key<>'platform'
     or v_execution_permit.namespace_code<>v_namespace
     or v_execution_permit.capability_code<>'reference_validation'
     or v_execution_permit.operation_code<>'secret_resolution'
     or v_execution_permit.maximum_uses<>1
     or not v_execution_permit.opaque_reference_contract
     or not v_execution_permit.metadata_only
     or v_execution_permit.executable
     or not v_execution_permit.revocable
     or v_execution_permit.bearer_credential
     or v_execution_permit.transferable
     or v_execution_permit.permit_execution_allowed
     or v_execution_permit.dispatch_allowed
     or v_execution_permit.endpoint_discovery_allowed
     or v_execution_permit.backend_contact_allowed
     or v_execution_permit.authentication_allowed
     or v_execution_permit.secret_lookup_allowed
     or v_execution_permit.secret_resolution_allowed
     or v_execution_permit.decryption_allowed
     or v_execution_permit.material_loading_allowed
     or v_execution_permit.delivery_allowed
     or v_execution_permit.network_access_allowed then
    raise exception 'MIGRATION_140_NON_EXECUTABLE_PERMIT_FAILED';
  end if;

  select * into strict v_permit_read
  from public.commercial_secret_resolution_execution_permit_read_model
  where permit_request_id=v_permit_request.id;

  if v_permit_read.effective_permit_status<>'eligible_metadata_only'
     or not v_permit_read.metadata_eligibility_current
     or v_permit_read.execution_authorized
     or v_permit_read.recorded_permit_status<>'issued'
     or not v_permit_read.metadata_only
     or v_permit_read.executable then
    raise exception
      'MIGRATION_140_INITIAL_EFFECTIVE_STATUS_FAILED status=%, eligibility=%, execution_authorized=%',
      v_permit_read.effective_permit_status,
      v_permit_read.metadata_eligibility_current,
      v_permit_read.execution_authorized;
  end if;

  v_permit_attempt :=
    public.record_blocked_secret_resolution_execution_permit_attempt(
      v_permit_request.id,
      'SECRET_RESOLUTION',
      'MIGRATION_140',
      jsonb_build_object(
        'temporary',true,
        'certification_probe',true,
        'expected_result','blocked'
      )
    );

  if v_permit_attempt.attempt_type<>'SECRET_RESOLUTION'
     or v_permit_attempt.attempt_status<>'blocked'
     or v_permit_attempt.block_code<>'NON_EXECUTABLE_PERMIT_OPERATION_FORBIDDEN'
     or v_permit_attempt.permit_request_id<>v_permit_request.id
     or v_permit_attempt.permit_decision_id<>v_permit_decision.id
     or v_permit_attempt.execution_permit_id<>v_execution_permit.id then
    raise exception 'MIGRATION_140_PERMIT_OPERATION_BLOCK_FAILED';
  end if;


  -- ===========================================================================
  -- 11. NON-DISPATCHABLE DISPATCH-ENVELOPE LIFECYCLE
  -- ===========================================================================

  v_envelope_request :=
    public.enqueue_commercial_secret_resolution_dispatch_envelope_request(
      'migration_140:envelope:'||v_suffix,
      'migration_140:envelope_idempotency:'||v_suffix,
      v_execution_permit.id,
      'production',
      'platform',
      'platform',
      v_namespace,
      'reference_validation',
      2,
      'MIGRATION_140',
      v_corr,
      v_cause,
      jsonb_build_object(
        'temporary',true,
        'certification','MIGRATION_140',
        'metadata_only',true,
        'dispatchable',false,
        'executable',false
      )
    );

  v_envelope_replay :=
    public.enqueue_commercial_secret_resolution_dispatch_envelope_request(
      'migration_140:envelope:'||v_suffix,
      'migration_140:envelope_idempotency:'||v_suffix,
      v_execution_permit.id,
      'production',
      'platform',
      'platform',
      v_namespace,
      'reference_validation',
      2,
      'MIGRATION_140',
      v_corr,
      v_cause,
      jsonb_build_object(
        'temporary',true,
        'certification','MIGRATION_140',
        'metadata_only',true,
        'dispatchable',false,
        'executable',false
      )
    );

  if v_envelope_replay.id<>v_envelope_request.id then
    raise exception 'MIGRATION_140_ENVELOPE_REPLAY_CREATED_DUPLICATE';
  end if;

  begin
    perform public.enqueue_commercial_secret_resolution_dispatch_envelope_request(
      'migration_140:envelope:'||v_suffix,
      'migration_140:envelope_idempotency:'||v_suffix,
      v_execution_permit.id,
      'production',
      'platform',
      'platform',
      v_namespace,
      'reference_validation',
      3,
      'MIGRATION_140',
      v_corr,
      v_cause,
      '{"temporary":true,"scenario":"IDEMPOTENCY_CONFLICT"}'::jsonb
    );

    raise exception 'MIGRATION_140_ENVELOPE_IDEMPOTENCY_CONFLICT_NOT_ENFORCED';
  exception
    when others then
      if sqlerrm='COMMERCIAL_SECRET_RESOLUTION_DISPATCH_ENVELOPE_IDEMPOTENCY_CONFLICT' then
        v_envelope_idempotency_conflict_guard:=true;
      else
        raise;
      end if;
  end;

  v_envelope_decision :=
    public.evaluate_commercial_secret_resolution_dispatch_envelope_request(
      v_envelope_request.id,
      'MIGRATION_140'
    );

  if v_envelope_decision.decision_status<>'approved'
     or v_envelope_decision.decision_code<>'ENVELOPE_METADATA_APPROVED'
     or not v_envelope_decision.approved
     or v_envelope_decision.execution_permit_id<>v_execution_permit.id
     or v_envelope_decision.selected_backend_binding_id<>v_binding.id
     or v_envelope_decision.selected_backend_id<>v_backend.id
     or v_envelope_decision.selected_backend_version_id<>v_backend_version.id
     or v_envelope_decision.resolved_environment<>'production'
     or v_envelope_decision.resolved_scope_type<>'platform'
     or v_envelope_decision.resolved_scope_key<>'platform'
     or v_envelope_decision.resolved_namespace<>v_namespace
     or v_envelope_decision.resolved_capability<>'reference_validation'
     or v_envelope_decision.resolved_operation<>'secret_resolution'
     or v_envelope_decision.granted_lifetime_seconds<>2
     or v_envelope_decision.not_before is null
     or v_envelope_decision.expires_at is null
     or v_envelope_decision.expires_at<=v_envelope_decision.not_before then
    raise exception 'MIGRATION_140_ENVELOPE_DECISION_FAILED';
  end if;

  if v_envelope_decision.dispatch_allowed
     or v_envelope_decision.queue_publication_allowed
     or v_envelope_decision.worker_claim_allowed
     or v_envelope_decision.permit_execution_allowed
     or v_envelope_decision.endpoint_discovery_allowed
     or v_envelope_decision.backend_contact_allowed
     or v_envelope_decision.authentication_allowed
     or v_envelope_decision.secret_lookup_allowed
     or v_envelope_decision.secret_resolution_allowed
     or v_envelope_decision.decryption_allowed
     or v_envelope_decision.material_loading_allowed
     or v_envelope_decision.delivery_allowed
     or v_envelope_decision.network_access_allowed then
    raise exception 'MIGRATION_140_ENVELOPE_DECISION_NOT_PASSIVE';
  end if;

  v_dispatch_envelope :=
    public.issue_commercial_secret_resolution_dispatch_envelope(
      v_envelope_request.id,
      'MIGRATION_140',
      jsonb_build_object(
        'temporary',true,
        'certification','MIGRATION_140',
        'metadata_only',true,
        'dispatchable',false,
        'executable',false
      )
    );

  if v_dispatch_envelope.envelope_status<>'held'
     or v_dispatch_envelope.envelope_request_id<>v_envelope_request.id
     or v_dispatch_envelope.envelope_decision_id<>v_envelope_decision.id
     or v_dispatch_envelope.execution_permit_id<>v_execution_permit.id
     or v_dispatch_envelope.permit_request_id<>v_permit_request.id
     or v_dispatch_envelope.permit_decision_id<>v_permit_decision.id
     or v_dispatch_envelope.selected_backend_binding_id<>v_binding.id
     or v_dispatch_envelope.selected_backend_id<>v_backend.id
     or v_dispatch_envelope.selected_backend_version_id<>v_backend_version.id
     or v_dispatch_envelope.environment<>'production'
     or v_dispatch_envelope.scope_type<>'platform'
     or v_dispatch_envelope.scope_key<>'platform'
     or v_dispatch_envelope.namespace_code<>v_namespace
     or v_dispatch_envelope.capability_code<>'reference_validation'
     or v_dispatch_envelope.operation_code<>'secret_resolution'
     or not v_dispatch_envelope.opaque_reference_contract
     or not v_dispatch_envelope.metadata_only
     or v_dispatch_envelope.executable
     or v_dispatch_envelope.dispatchable
     or v_dispatch_envelope.transferable
     or v_dispatch_envelope.queue_publishable
     or v_dispatch_envelope.worker_claimable
     or v_dispatch_envelope.dispatch_allowed
     or v_dispatch_envelope.queue_publication_allowed
     or v_dispatch_envelope.worker_claim_allowed
     or v_dispatch_envelope.permit_execution_allowed
     or v_dispatch_envelope.endpoint_discovery_allowed
     or v_dispatch_envelope.backend_contact_allowed
     or v_dispatch_envelope.authentication_allowed
     or v_dispatch_envelope.secret_lookup_allowed
     or v_dispatch_envelope.secret_resolution_allowed
     or v_dispatch_envelope.decryption_allowed
     or v_dispatch_envelope.material_loading_allowed
     or v_dispatch_envelope.delivery_allowed
     or v_dispatch_envelope.network_access_allowed then
    raise exception 'MIGRATION_140_NON_DISPATCHABLE_ENVELOPE_FAILED';
  end if;

  select * into strict v_envelope_read
  from public.commercial_secret_resolution_dispatch_envelope_read_model
  where envelope_request_id=v_envelope_request.id;

  if v_envelope_read.effective_envelope_status<>'held_metadata_only'
     or not v_envelope_read.metadata_envelope_current
     or v_envelope_read.dispatch_authorized
     or v_envelope_read.execution_authorized
     or not v_envelope_read.metadata_only
     or v_envelope_read.executable
     or v_envelope_read.dispatchable
     or v_envelope_read.queue_publishable
     or v_envelope_read.worker_claimable then
    raise exception
      'MIGRATION_140_INITIAL_ENVELOPE_STATUS_FAILED status=%, current=%, dispatch_authorized=%, execution_authorized=%',
      v_envelope_read.effective_envelope_status,
      v_envelope_read.metadata_envelope_current,
      v_envelope_read.dispatch_authorized,
      v_envelope_read.execution_authorized;
  end if;


  -- ===========================================================================
  -- 12. HELD DISPATCH-ADMISSION TICKET LIFECYCLE
  -- ===========================================================================

  v_admission_request :=
    public.enqueue_commercial_secret_resolution_dispatch_admission_request(
      'migration_140:admission:'||v_suffix,
      'migration_140:admission_idempotency:'||v_suffix,
      v_dispatch_envelope.id,
      'production',
      'platform',
      'platform',
      v_namespace,
      'reference_validation',
      1,
      'MIGRATION_140',
      v_corr,
      v_cause,
      jsonb_build_object(
        'temporary',true,
        'certification','MIGRATION_140',
        'metadata_only',true,
        'publishable',false,
        'claimable',false,
        'dispatchable',false,
        'executable',false
      )
    );

  v_admission_replay :=
    public.enqueue_commercial_secret_resolution_dispatch_admission_request(
      'migration_140:admission:'||v_suffix,
      'migration_140:admission_idempotency:'||v_suffix,
      v_dispatch_envelope.id,
      'production',
      'platform',
      'platform',
      v_namespace,
      'reference_validation',
      1,
      'MIGRATION_140',
      v_corr,
      v_cause,
      jsonb_build_object(
        'temporary',true,
        'certification','MIGRATION_140',
        'metadata_only',true,
        'publishable',false,
        'claimable',false,
        'dispatchable',false,
        'executable',false
      )
    );

  if v_admission_replay.id<>v_admission_request.id then
    raise exception 'MIGRATION_140_ADMISSION_REPLAY_CREATED_DUPLICATE';
  end if;

  begin
    perform public.enqueue_commercial_secret_resolution_dispatch_admission_request(
      'migration_140:admission:'||v_suffix,
      'migration_140:admission_idempotency:'||v_suffix,
      v_dispatch_envelope.id,
      'production',
      'platform',
      'platform',
      v_namespace,
      'reference_validation',
      2,
      'MIGRATION_140',
      v_corr,
      v_cause,
      '{"temporary":true,"scenario":"IDEMPOTENCY_CONFLICT"}'::jsonb
    );

    raise exception 'MIGRATION_140_ADMISSION_IDEMPOTENCY_CONFLICT_NOT_ENFORCED';
  exception
    when others then
      if sqlerrm='COMMERCIAL_SECRET_RESOLUTION_DISPATCH_ADMISSION_IDEMPOTENCY_CONFLICT' then
        v_admission_idempotency_conflict_guard:=true;
      else
        raise;
      end if;
  end;

  v_admission_decision :=
    public.evaluate_commercial_secret_resolution_dispatch_admission_request(
      v_admission_request.id,
      'MIGRATION_140'
    );

  if v_admission_decision.decision_status<>'approved'
     or v_admission_decision.decision_code<>'ADMISSION_METADATA_APPROVED'
     or not v_admission_decision.approved
     or v_admission_decision.dispatch_envelope_id<>v_dispatch_envelope.id
     or v_admission_decision.execution_permit_id<>v_execution_permit.id
     or v_admission_decision.selected_backend_binding_id<>v_binding.id
     or v_admission_decision.selected_backend_id<>v_backend.id
     or v_admission_decision.selected_backend_version_id<>v_backend_version.id
     or v_admission_decision.resolved_environment<>'production'
     or v_admission_decision.resolved_scope_type<>'platform'
     or v_admission_decision.resolved_scope_key<>'platform'
     or v_admission_decision.resolved_namespace<>v_namespace
     or v_admission_decision.resolved_capability<>'reference_validation'
     or v_admission_decision.resolved_operation<>'secret_resolution'
     or v_admission_decision.granted_lifetime_seconds<>1
     or v_admission_decision.not_before is null
     or v_admission_decision.expires_at is null
     or v_admission_decision.expires_at<=v_admission_decision.not_before then
    raise exception 'MIGRATION_140_ADMISSION_DECISION_FAILED';
  end if;

  if v_admission_decision.queue_publication_allowed
     or v_admission_decision.runtime_job_creation_allowed
     or v_admission_decision.worker_lease_allowed
     or v_admission_decision.worker_claim_allowed
     or v_admission_decision.dispatch_allowed
     or v_admission_decision.envelope_execution_allowed
     or v_admission_decision.permit_execution_allowed
     or v_admission_decision.endpoint_discovery_allowed
     or v_admission_decision.backend_contact_allowed
     or v_admission_decision.authentication_allowed
     or v_admission_decision.secret_lookup_allowed
     or v_admission_decision.secret_resolution_allowed
     or v_admission_decision.decryption_allowed
     or v_admission_decision.material_loading_allowed
     or v_admission_decision.delivery_allowed
     or v_admission_decision.network_access_allowed then
    raise exception 'MIGRATION_140_ADMISSION_DECISION_NOT_PASSIVE';
  end if;

  v_admission_ticket :=
    public.issue_commercial_secret_resolution_dispatch_admission_ticket(
      v_admission_request.id,
      'MIGRATION_140',
      jsonb_build_object(
        'temporary',true,
        'certification','MIGRATION_140',
        'metadata_only',true,
        'publishable',false,
        'claimable',false,
        'dispatchable',false,
        'executable',false
      )
    );

  if v_admission_ticket.ticket_status<>'held'
     or v_admission_ticket.admission_request_id<>v_admission_request.id
     or v_admission_ticket.admission_decision_id<>v_admission_decision.id
     or v_admission_ticket.dispatch_envelope_id<>v_dispatch_envelope.id
     or v_admission_ticket.envelope_request_id<>v_envelope_request.id
     or v_admission_ticket.envelope_decision_id<>v_envelope_decision.id
     or v_admission_ticket.execution_permit_id<>v_execution_permit.id
     or v_admission_ticket.selected_backend_binding_id<>v_binding.id
     or v_admission_ticket.selected_backend_id<>v_backend.id
     or v_admission_ticket.selected_backend_version_id<>v_backend_version.id
     or v_admission_ticket.environment<>'production'
     or v_admission_ticket.scope_type<>'platform'
     or v_admission_ticket.scope_key<>'platform'
     or v_admission_ticket.namespace_code<>v_namespace
     or v_admission_ticket.capability_code<>'reference_validation'
     or v_admission_ticket.operation_code<>'secret_resolution'
     or not v_admission_ticket.opaque_reference_contract
     or not v_admission_ticket.metadata_only
     or v_admission_ticket.executable
     or v_admission_ticket.publishable
     or v_admission_ticket.leaseable
     or v_admission_ticket.claimable
     or v_admission_ticket.dispatchable
     or v_admission_ticket.transferable
     or v_admission_ticket.queue_publication_allowed
     or v_admission_ticket.runtime_job_creation_allowed
     or v_admission_ticket.worker_lease_allowed
     or v_admission_ticket.worker_claim_allowed
     or v_admission_ticket.dispatch_allowed
     or v_admission_ticket.envelope_execution_allowed
     or v_admission_ticket.permit_execution_allowed
     or v_admission_ticket.endpoint_discovery_allowed
     or v_admission_ticket.backend_contact_allowed
     or v_admission_ticket.authentication_allowed
     or v_admission_ticket.secret_lookup_allowed
     or v_admission_ticket.secret_resolution_allowed
     or v_admission_ticket.decryption_allowed
     or v_admission_ticket.material_loading_allowed
     or v_admission_ticket.delivery_allowed
     or v_admission_ticket.network_access_allowed then
    raise exception 'MIGRATION_140_HELD_ADMISSION_TICKET_FAILED';
  end if;

  select * into strict v_admission_read
  from public.commercial_secret_resolution_dispatch_admission_read_model
  where admission_request_id=v_admission_request.id;

  if v_admission_read.effective_ticket_status<>'held_metadata_only'
     or not v_admission_read.metadata_ticket_current
     or v_admission_read.queue_publication_authorized
     or v_admission_read.worker_claim_authorized
     or v_admission_read.dispatch_authorized
     or v_admission_read.execution_authorized
     or not v_admission_read.metadata_only
     or v_admission_read.executable
     or v_admission_read.publishable
     or v_admission_read.leaseable
     or v_admission_read.claimable
     or v_admission_read.dispatchable then
    raise exception
      'MIGRATION_140_INITIAL_ADMISSION_STATUS_FAILED status=%, current=%, publication_authorized=%, claim_authorized=%, dispatch_authorized=%, execution_authorized=%',
      v_admission_read.effective_ticket_status,
      v_admission_read.metadata_ticket_current,
      v_admission_read.queue_publication_authorized,
      v_admission_read.worker_claim_authorized,
      v_admission_read.dispatch_authorized,
      v_admission_read.execution_authorized;
  end if;

  v_admission_attempt :=
    public.record_blocked_secret_resolution_dispatch_admission_attempt(
      v_admission_request.id,
      'QUEUE_PUBLICATION',
      'MIGRATION_140',
      jsonb_build_object(
        'temporary',true,
        'certification_probe',true,
        'expected_result','blocked'
      )
    );

  if v_admission_attempt.attempt_type<>'QUEUE_PUBLICATION'
     or v_admission_attempt.attempt_status<>'blocked'
     or v_admission_attempt.block_code<>'NON_EXECUTABLE_ADMISSION_OPERATION_FORBIDDEN'
     or v_admission_attempt.admission_request_id<>v_admission_request.id
     or v_admission_attempt.admission_decision_id<>v_admission_decision.id
     or v_admission_attempt.admission_ticket_id<>v_admission_ticket.id then
    raise exception 'MIGRATION_140_ADMISSION_OPERATION_BLOCK_FAILED';
  end if;

  perform pg_sleep(1.2);

  select * into strict v_admission_read
  from public.commercial_secret_resolution_dispatch_admission_read_model
  where admission_request_id=v_admission_request.id;

  if v_admission_read.effective_ticket_status<>'expired'
     or v_admission_read.metadata_ticket_current
     or v_admission_read.queue_publication_authorized
     or v_admission_read.worker_claim_authorized
     or v_admission_read.dispatch_authorized
     or v_admission_read.execution_authorized then
    raise exception
      'MIGRATION_140_ADMISSION_EXPIRY_FAILED status=%, current=%, publication_authorized=%, claim_authorized=%, dispatch_authorized=%, execution_authorized=%',
      v_admission_read.effective_ticket_status,
      v_admission_read.metadata_ticket_current,
      v_admission_read.queue_publication_authorized,
      v_admission_read.worker_claim_authorized,
      v_admission_read.dispatch_authorized,
      v_admission_read.execution_authorized;
  end if;

  v_admission_cancellation :=
    public.cancel_commercial_secret_resolution_dispatch_admission_ticket(
      v_admission_ticket.id,
      'migration_140:admission_cancellation:'||v_suffix,
      'TEST_CANCELLATION',
      'Lifecycle certification cancellation after ticket expiry',
      'MIGRATION_140',
      v_corr,
      v_cause,
      '{"temporary":true,"certification":"MIGRATION_140"}'::jsonb
    );

  select * into strict v_admission_read
  from public.commercial_secret_resolution_dispatch_admission_read_model
  where admission_request_id=v_admission_request.id;

  if v_admission_read.effective_ticket_status<>'cancelled'
     or v_admission_read.metadata_ticket_current
     or v_admission_read.queue_publication_authorized
     or v_admission_read.worker_claim_authorized
     or v_admission_read.dispatch_authorized
     or v_admission_read.execution_authorized
     or v_admission_read.cancellation_id<>v_admission_cancellation.id then
    raise exception 'MIGRATION_140_ADMISSION_CANCELLATION_FAILED';
  end if;

  select count(*) into v_admission_request_count
  from public.commercial_secret_resolution_dispatch_admission_requests
  where id=v_admission_request.id;

  select count(*) into v_admission_idempotency_count
  from public.commercial_secret_resolution_dispatch_admission_idempotency
  where admission_request_id=v_admission_request.id;

  select count(*) into v_admission_evaluation_count
  from public.commercial_secret_resolution_dispatch_admission_evaluations
  where admission_request_id=v_admission_request.id;

  select count(*) into v_admission_decision_count
  from public.commercial_secret_resolution_dispatch_admission_decisions
  where admission_request_id=v_admission_request.id;

  select count(*) into v_admission_ticket_count
  from public.commercial_secret_resolution_dispatch_admission_tickets
  where admission_request_id=v_admission_request.id;

  select count(*) into v_admission_cancellation_count
  from public.commercial_secret_resolution_dispatch_admission_cancellations
  where admission_ticket_id=v_admission_ticket.id;

  select count(*) into v_admission_attempt_count
  from public.commercial_secret_resolution_dispatch_admission_attempts
  where admission_request_id=v_admission_request.id;

  select count(*) into v_admission_receipt_count
  from public.commercial_secret_resolution_dispatch_admission_receipts
  where admission_request_id=v_admission_request.id;

  select count(*) into v_admission_event_count
  from public.commercial_secret_resolution_dispatch_admission_events
  where admission_request_id=v_admission_request.id;

  select replay_count into strict v_admission_replay_count
  from public.commercial_secret_resolution_dispatch_admission_idempotency
  where admission_request_id=v_admission_request.id;

  if v_admission_request_count<>1
     or v_admission_idempotency_count<>1
     or v_admission_evaluation_count<>10
     or v_admission_decision_count<>1
     or v_admission_ticket_count<>1
     or v_admission_cancellation_count<>1
     or v_admission_attempt_count<>1
     or v_admission_receipt_count<>7
     or v_admission_event_count<>6
     or v_admission_replay_count<>1 then
    raise exception
      'MIGRATION_140_ADMISSION_COUNT_ASSERTION_FAILED request=%, idempotency=%, evaluations=%, decision=%, ticket=%, cancellation=%, attempt=%, receipts=%, events=%, replay=%',
      v_admission_request_count,v_admission_idempotency_count,
      v_admission_evaluation_count,v_admission_decision_count,
      v_admission_ticket_count,v_admission_cancellation_count,
      v_admission_attempt_count,v_admission_receipt_count,
      v_admission_event_count,v_admission_replay_count;
  end if;

  begin
    update public.commercial_secret_resolution_dispatch_admission_policies
    set policy_version=policy_version+1
    where id=v_admission_policy.id;
    raise exception 'MIGRATION_140_ADMISSION_POLICY_GUARD_NOT_ENFORCED';
  exception when others then
    if sqlerrm='COMMERCIAL_SECRET_RESOLUTION_DISPATCH_ADMISSION_IMMUTABLE' then
      v_admission_policy_guard:=true;
    else
      raise;
    end if;
  end;

  begin
    update public.commercial_secret_resolution_dispatch_admission_evaluations
    set evaluation_reason='MUTATED'
    where admission_request_id=v_admission_request.id;
    raise exception 'MIGRATION_140_ADMISSION_EVALUATION_GUARD_NOT_ENFORCED';
  exception when others then
    if sqlerrm='COMMERCIAL_SECRET_RESOLUTION_DISPATCH_ADMISSION_IMMUTABLE' then
      v_admission_evaluation_guard:=true;
    else
      raise;
    end if;
  end;

  begin
    update public.commercial_secret_resolution_dispatch_admission_decisions
    set decision_reason='MUTATED'
    where id=v_admission_decision.id;
    raise exception 'MIGRATION_140_ADMISSION_DECISION_GUARD_NOT_ENFORCED';
  exception when others then
    if sqlerrm='COMMERCIAL_SECRET_RESOLUTION_DISPATCH_ADMISSION_IMMUTABLE' then
      v_admission_decision_guard:=true;
    else
      raise;
    end if;
  end;

  begin
    update public.commercial_secret_resolution_dispatch_admission_tickets
    set ticket_status='cancelled'
    where id=v_admission_ticket.id;
    raise exception 'MIGRATION_140_ADMISSION_TICKET_GUARD_NOT_ENFORCED';
  exception when others then
    if sqlerrm='COMMERCIAL_SECRET_RESOLUTION_DISPATCH_ADMISSION_IMMUTABLE' then
      v_admission_ticket_guard:=true;
    else
      raise;
    end if;
  end;

  begin
    delete from public.commercial_secret_resolution_dispatch_admission_cancellations
    where id=v_admission_cancellation.id;
    raise exception 'MIGRATION_140_ADMISSION_CANCELLATION_GUARD_NOT_ENFORCED';
  exception when others then
    if sqlerrm='COMMERCIAL_SECRET_RESOLUTION_DISPATCH_ADMISSION_APPEND_ONLY' then
      v_admission_cancellation_guard:=true;
    else
      raise;
    end if;
  end;

  begin
    delete from public.commercial_secret_resolution_dispatch_admission_attempts
    where id=v_admission_attempt.id;
    raise exception 'MIGRATION_140_ADMISSION_ATTEMPT_GUARD_NOT_ENFORCED';
  exception when others then
    if sqlerrm='COMMERCIAL_SECRET_RESOLUTION_DISPATCH_ADMISSION_APPEND_ONLY' then
      v_admission_attempt_guard:=true;
    else
      raise;
    end if;
  end;

  begin
    update public.commercial_secret_resolution_dispatch_admission_receipts
    set receipt_message='MUTATED'
    where admission_request_id=v_admission_request.id;
    raise exception 'MIGRATION_140_ADMISSION_RECEIPT_GUARD_NOT_ENFORCED';
  exception when others then
    if sqlerrm='COMMERCIAL_SECRET_RESOLUTION_DISPATCH_ADMISSION_APPEND_ONLY' then
      v_admission_receipt_guard:=true;
    else
      raise;
    end if;
  end;

  begin
    delete from public.commercial_secret_resolution_dispatch_admission_events
    where admission_request_id=v_admission_request.id;
    raise exception 'MIGRATION_140_ADMISSION_EVENT_GUARD_NOT_ENFORCED';
  exception when others then
    if sqlerrm='COMMERCIAL_SECRET_RESOLUTION_DISPATCH_ADMISSION_APPEND_ONLY' then
      v_admission_event_guard:=true;
    else
      raise;
    end if;
  end;

  begin
    insert into public.commercial_secret_resolution_dispatch_admission_requests(
      request_key,idempotency_key,admission_policy_id,dispatch_envelope_id,
      envelope_request_id,envelope_decision_id,execution_permit_id,
      requested_environment,requested_scope_type,requested_scope_key,
      requested_namespace,requested_capability,requested_operation,
      requested_lifetime_seconds,request_status,correlation_id,requested_by,
      request_hash,request_metadata
    ) values (
      'migration_140:admission_plaintext:'||v_suffix,
      'migration_140:admission_plaintext_idem:'||v_suffix,
      v_admission_policy.id,v_dispatch_envelope.id,v_envelope_request.id,
      v_envelope_decision.id,v_execution_permit.id,'production','platform',
      'platform',v_namespace,'reference_validation','secret_resolution',
      1,'received',v_corr,'MIGRATION_140',repeat('a',64),
      '{"api_key":"FORBIDDEN"}'::jsonb
    );
    raise exception 'MIGRATION_140_ADMISSION_PLAINTEXT_GUARD_NOT_ENFORCED';
  exception when check_violation then
    v_admission_plaintext_guard:=true;
  end;

  begin
    insert into public.commercial_secret_resolution_dispatch_admission_requests(
      request_key,idempotency_key,admission_policy_id,dispatch_envelope_id,
      envelope_request_id,envelope_decision_id,execution_permit_id,
      requested_environment,requested_scope_type,requested_scope_key,
      requested_namespace,requested_capability,requested_operation,
      requested_lifetime_seconds,request_status,correlation_id,requested_by,
      request_hash,request_metadata
    ) values (
      'migration_140:admission_endpoint:'||v_suffix,
      'migration_140:admission_endpoint_idem:'||v_suffix,
      v_admission_policy.id,v_dispatch_envelope.id,v_envelope_request.id,
      v_envelope_decision.id,v_execution_permit.id,'production','platform',
      'platform',v_namespace,'reference_validation','secret_resolution',
      1,'received',v_corr,'MIGRATION_140',repeat('b',64),
      '{"endpoint":"forbidden.example"}'::jsonb
    );
    raise exception 'MIGRATION_140_ADMISSION_ENDPOINT_GUARD_NOT_ENFORCED';
  exception when check_violation then
    v_admission_endpoint_guard:=true;
  end;

  begin
    insert into public.commercial_secret_resolution_dispatch_admission_requests(
      request_key,idempotency_key,admission_policy_id,dispatch_envelope_id,
      envelope_request_id,envelope_decision_id,execution_permit_id,
      requested_environment,requested_scope_type,requested_scope_key,
      requested_namespace,requested_capability,requested_operation,
      requested_lifetime_seconds,request_status,correlation_id,requested_by,
      request_hash,request_metadata
    ) values (
      'migration_140:admission_probe:'||v_suffix,
      'migration_140:admission_probe_idem:'||v_suffix,
      v_admission_policy.id,v_dispatch_envelope.id,v_envelope_request.id,
      v_envelope_decision.id,v_execution_permit.id,'production','platform',
      'platform',v_namespace,'reference_validation','secret_resolution',
      1,'approved',v_corr,'MIGRATION_140',repeat('c',64),
      '{"temporary":true,"guard_probe":true}'::jsonb
    ) returning id into v_probe_admission_request_id;

    insert into public.commercial_secret_resolution_dispatch_admission_decisions(
      admission_request_id,decision_status,decision_code,approved,
      dispatch_envelope_id,execution_permit_id,selected_backend_binding_id,
      selected_backend_id,selected_backend_version_id,resolved_environment,
      resolved_scope_type,resolved_scope_key,resolved_namespace,
      resolved_capability,resolved_operation,granted_lifetime_seconds,
      not_before,expires_at,decided_by,decision_reason,decision_hash,
      decision_metadata
    ) values (
      v_probe_admission_request_id,'approved','ADMISSION_METADATA_APPROVED',
      true,v_dispatch_envelope.id,v_execution_permit.id,v_binding.id,
      v_backend.id,v_backend_version.id,'production','platform','platform',
      v_namespace,'reference_validation','secret_resolution',1,
      clock_timestamp(),clock_timestamp()+interval '1 second',
      'MIGRATION_140','Temporary decision for executable-ticket guard',
      repeat('d',64),'{"temporary":true,"guard_probe":true}'::jsonb
    ) returning id into v_probe_admission_decision_id;

    insert into public.commercial_secret_resolution_dispatch_admission_tickets(
      ticket_key,admission_request_id,admission_decision_id,
      dispatch_envelope_id,envelope_request_id,envelope_decision_id,
      execution_permit_id,selected_backend_binding_id,selected_backend_id,
      selected_backend_version_id,environment,scope_type,scope_key,
      namespace_code,capability_code,operation_code,ticket_status,
      not_before,expires_at,opaque_reference_contract,metadata_only,
      executable,publishable,leaseable,claimable,dispatchable,transferable,
      ticket_hash,ticket_metadata,issued_by
    ) values (
      'migration_140:executable_ticket:'||v_suffix,
      v_probe_admission_request_id,v_probe_admission_decision_id,
      v_dispatch_envelope.id,v_envelope_request.id,v_envelope_decision.id,
      v_execution_permit.id,v_binding.id,v_backend.id,v_backend_version.id,
      'production','platform','platform',v_namespace,'reference_validation',
      'secret_resolution','held',clock_timestamp(),
      clock_timestamp()+interval '1 second',true,true,true,false,false,false,
      false,false,repeat('e',64),
      '{"temporary":true,"guard_probe":true}'::jsonb,'MIGRATION_140'
    );
    raise exception 'MIGRATION_140_EXECUTABLE_TICKET_GUARD_NOT_ENFORCED';
  exception when check_violation then
    v_executable_ticket_guard:=true;
  end;

  if not (
    v_admission_idempotency_conflict_guard
    and v_admission_policy_guard
    and v_admission_evaluation_guard
    and v_admission_decision_guard
    and v_admission_ticket_guard
    and v_admission_cancellation_guard
    and v_admission_attempt_guard
    and v_admission_receipt_guard
    and v_admission_event_guard
    and v_admission_plaintext_guard
    and v_admission_endpoint_guard
    and v_executable_ticket_guard
  ) then
    raise exception 'MIGRATION_140_ADMISSION_GUARD_MATRIX_FAILED';
  end if;

  raise notice
    'MIGRATION_140_DISPATCH_ADMISSION_LIFECYCLE_CERTIFIED request_count=%, idempotency_count=%, evaluation_count=%, decision_count=%, ticket_count=%, cancellation_count=%, attempt_count=%, receipt_count=%, event_count=%, replay_count=%, decision_status=approved, decision_code=ADMISSION_METADATA_APPROVED, initial_effective_status=held_metadata_only, expiry_status=expired, final_effective_status=cancelled, attempt_status=blocked, attempt_code=NON_EXECUTABLE_ADMISSION_OPERATION_FORBIDDEN, idempotency_conflict_guard=%, policy_guard=%, evaluation_guard=%, decision_guard=%, ticket_guard=%, cancellation_guard=%, attempt_guard=%, receipt_guard=%, event_guard=%, plaintext_guard=%, endpoint_guard=%, executable_ticket_guard=%, metadata_only=true, executable=false, publishable=false, leaseable=false, claimable=false, dispatchable=false, transferable=false, queue_publication_authorized=false, worker_claim_authorized=false, dispatch_authorized=false, execution_authorized=false',
    v_admission_request_count,v_admission_idempotency_count,
    v_admission_evaluation_count,v_admission_decision_count,
    v_admission_ticket_count,v_admission_cancellation_count,
    v_admission_attempt_count,v_admission_receipt_count,
    v_admission_event_count,v_admission_replay_count,
    v_admission_idempotency_conflict_guard,v_admission_policy_guard,
    v_admission_evaluation_guard,v_admission_decision_guard,
    v_admission_ticket_guard,v_admission_cancellation_guard,
    v_admission_attempt_guard,v_admission_receipt_guard,
    v_admission_event_guard,v_admission_plaintext_guard,
    v_admission_endpoint_guard,v_executable_ticket_guard;

  v_envelope_attempt :=
    public.record_blocked_secret_resolution_dispatch_envelope_attempt(
      v_envelope_request.id,
      'DISPATCH',
      'MIGRATION_140',
      jsonb_build_object(
        'temporary',true,
        'certification_probe',true,
        'expected_result','blocked'
      )
    );

  if v_envelope_attempt.attempt_type<>'DISPATCH'
     or v_envelope_attempt.attempt_status<>'blocked'
     or v_envelope_attempt.block_code<>'NON_DISPATCHABLE_ENVELOPE_OPERATION_FORBIDDEN'
     or v_envelope_attempt.envelope_request_id<>v_envelope_request.id
     or v_envelope_attempt.envelope_decision_id<>v_envelope_decision.id
     or v_envelope_attempt.dispatch_envelope_id<>v_dispatch_envelope.id then
    raise exception 'MIGRATION_140_ENVELOPE_OPERATION_BLOCK_FAILED';
  end if;

  perform pg_sleep(1.1);

  select * into strict v_envelope_read
  from public.commercial_secret_resolution_dispatch_envelope_read_model
  where envelope_request_id=v_envelope_request.id;

  if v_envelope_read.effective_envelope_status<>'expired'
     or v_envelope_read.metadata_envelope_current
     or v_envelope_read.dispatch_authorized
     or v_envelope_read.execution_authorized then
    raise exception
      'MIGRATION_140_ENVELOPE_EXPIRY_FAILED status=%, current=%, dispatch_authorized=%, execution_authorized=%',
      v_envelope_read.effective_envelope_status,
      v_envelope_read.metadata_envelope_current,
      v_envelope_read.dispatch_authorized,
      v_envelope_read.execution_authorized;
  end if;

  v_envelope_cancellation :=
    public.cancel_commercial_secret_resolution_dispatch_envelope(
      v_dispatch_envelope.id,
      'migration_140:cancellation:'||v_suffix,
      'TEST_CANCELLATION',
      'Lifecycle certification cancellation after expiry',
      'MIGRATION_140',
      v_corr,
      v_cause,
      '{"temporary":true,"certification":"MIGRATION_140"}'::jsonb
    );

  select * into strict v_envelope_read
  from public.commercial_secret_resolution_dispatch_envelope_read_model
  where envelope_request_id=v_envelope_request.id;

  if v_envelope_read.effective_envelope_status<>'cancelled'
     or v_envelope_read.metadata_envelope_current
     or v_envelope_read.dispatch_authorized
     or v_envelope_read.execution_authorized
     or v_envelope_read.cancellation_id<>v_envelope_cancellation.id then
    raise exception 'MIGRATION_140_ENVELOPE_CANCELLATION_FAILED';
  end if;

  select count(*) into v_envelope_request_count
  from public.commercial_secret_resolution_dispatch_envelope_requests
  where id=v_envelope_request.id;

  select count(*) into v_envelope_idempotency_count
  from public.commercial_secret_resolution_dispatch_envelope_idempotency
  where envelope_request_id=v_envelope_request.id;

  select count(*) into v_envelope_evaluation_count
  from public.commercial_secret_resolution_dispatch_envelope_evaluations
  where envelope_request_id=v_envelope_request.id;

  select count(*) into v_envelope_decision_count
  from public.commercial_secret_resolution_dispatch_envelope_decisions
  where envelope_request_id=v_envelope_request.id;

  select count(*) into v_dispatch_envelope_count
  from public.commercial_secret_resolution_dispatch_envelopes
  where envelope_request_id=v_envelope_request.id;

  select count(*) into v_envelope_cancellation_count
  from public.commercial_secret_resolution_dispatch_envelope_cancellations
  where dispatch_envelope_id=v_dispatch_envelope.id;

  select count(*) into v_envelope_attempt_count
  from public.commercial_secret_resolution_dispatch_envelope_attempts
  where envelope_request_id=v_envelope_request.id;

  select count(*) into v_envelope_receipt_count
  from public.commercial_secret_resolution_dispatch_envelope_receipts
  where envelope_request_id=v_envelope_request.id;

  select count(*) into v_envelope_event_count
  from public.commercial_secret_resolution_dispatch_envelope_events
  where envelope_request_id=v_envelope_request.id;

  select replay_count into strict v_envelope_replay_count
  from public.commercial_secret_resolution_dispatch_envelope_idempotency
  where envelope_request_id=v_envelope_request.id;

  if v_envelope_request_count<>1
     or v_envelope_idempotency_count<>1
     or v_envelope_evaluation_count<>11
     or v_envelope_decision_count<>1
     or v_dispatch_envelope_count<>1
     or v_envelope_cancellation_count<>1
     or v_envelope_attempt_count<>1
     or v_envelope_receipt_count<>7
     or v_envelope_event_count<>6
     or v_envelope_replay_count<>1 then
    raise exception
      'MIGRATION_140_ENVELOPE_COUNT_ASSERTION_FAILED request=%, idempotency=%, evaluations=%, decision=%, envelope=%, cancellation=%, attempt=%, receipts=%, events=%, replay=%',
      v_envelope_request_count,v_envelope_idempotency_count,v_envelope_evaluation_count,
      v_envelope_decision_count,v_dispatch_envelope_count,v_envelope_cancellation_count,
      v_envelope_attempt_count,v_envelope_receipt_count,v_envelope_event_count,
      v_envelope_replay_count;
  end if;

  begin
    update public.commercial_secret_resolution_dispatch_envelope_policies
    set policy_version=policy_version+1 where id=v_envelope_policy.id;
    raise exception 'MIGRATION_140_ENVELOPE_POLICY_GUARD_NOT_ENFORCED';
  exception when others then
    if sqlerrm='COMMERCIAL_SECRET_RESOLUTION_DISPATCH_ENVELOPE_IMMUTABLE' then
      v_envelope_policy_guard:=true;
    else raise;
    end if;
  end;

  begin
    update public.commercial_secret_resolution_dispatch_envelope_evaluations
    set evaluation_reason='MUTATED' where envelope_request_id=v_envelope_request.id;
    raise exception 'MIGRATION_140_ENVELOPE_EVALUATION_GUARD_NOT_ENFORCED';
  exception when others then
    if sqlerrm='COMMERCIAL_SECRET_RESOLUTION_DISPATCH_ENVELOPE_IMMUTABLE' then
      v_envelope_evaluation_guard:=true;
    else raise;
    end if;
  end;

  begin
    update public.commercial_secret_resolution_dispatch_envelope_decisions
    set decision_reason='MUTATED' where id=v_envelope_decision.id;
    raise exception 'MIGRATION_140_ENVELOPE_DECISION_GUARD_NOT_ENFORCED';
  exception when others then
    if sqlerrm='COMMERCIAL_SECRET_RESOLUTION_DISPATCH_ENVELOPE_IMMUTABLE' then
      v_envelope_decision_guard:=true;
    else raise;
    end if;
  end;

  begin
    update public.commercial_secret_resolution_dispatch_envelopes
    set envelope_status='cancelled' where id=v_dispatch_envelope.id;
    raise exception 'MIGRATION_140_DISPATCH_ENVELOPE_GUARD_NOT_ENFORCED';
  exception when others then
    if sqlerrm='COMMERCIAL_SECRET_RESOLUTION_DISPATCH_ENVELOPE_IMMUTABLE' then
      v_dispatch_envelope_guard:=true;
    else raise;
    end if;
  end;

  begin
    delete from public.commercial_secret_resolution_dispatch_envelope_cancellations
    where id=v_envelope_cancellation.id;
    raise exception 'MIGRATION_140_ENVELOPE_CANCELLATION_GUARD_NOT_ENFORCED';
  exception when others then
    if sqlerrm='COMMERCIAL_SECRET_RESOLUTION_DISPATCH_ENVELOPE_APPEND_ONLY' then
      v_envelope_cancellation_guard:=true;
    else raise;
    end if;
  end;

  begin
    delete from public.commercial_secret_resolution_dispatch_envelope_attempts
    where id=v_envelope_attempt.id;
    raise exception 'MIGRATION_140_ENVELOPE_ATTEMPT_GUARD_NOT_ENFORCED';
  exception when others then
    if sqlerrm='COMMERCIAL_SECRET_RESOLUTION_DISPATCH_ENVELOPE_APPEND_ONLY' then
      v_envelope_attempt_guard:=true;
    else raise;
    end if;
  end;

  begin
    update public.commercial_secret_resolution_dispatch_envelope_receipts
    set receipt_message='MUTATED' where envelope_request_id=v_envelope_request.id;
    raise exception 'MIGRATION_140_ENVELOPE_RECEIPT_GUARD_NOT_ENFORCED';
  exception when others then
    if sqlerrm='COMMERCIAL_SECRET_RESOLUTION_DISPATCH_ENVELOPE_APPEND_ONLY' then
      v_envelope_receipt_guard:=true;
    else raise;
    end if;
  end;

  begin
    delete from public.commercial_secret_resolution_dispatch_envelope_events
    where envelope_request_id=v_envelope_request.id;
    raise exception 'MIGRATION_140_ENVELOPE_EVENT_GUARD_NOT_ENFORCED';
  exception when others then
    if sqlerrm='COMMERCIAL_SECRET_RESOLUTION_DISPATCH_ENVELOPE_APPEND_ONLY' then
      v_envelope_event_guard:=true;
    else raise;
    end if;
  end;

  begin
    insert into public.commercial_secret_resolution_dispatch_envelope_requests(
      request_key,idempotency_key,envelope_policy_id,execution_permit_id,
      permit_request_id,permit_decision_id,requested_environment,requested_scope_type,
      requested_scope_key,requested_namespace,requested_capability,requested_operation,
      requested_lifetime_seconds,request_status,correlation_id,requested_by,
      request_hash,request_metadata
    ) values (
      'migration_140:envelope_plaintext:'||v_suffix,
      'migration_140:envelope_plaintext_idem:'||v_suffix,
      v_envelope_policy.id,v_execution_permit.id,v_permit_request.id,v_permit_decision.id,
      'production','platform','platform',v_namespace,'reference_validation',
      'secret_resolution',1,'received',v_corr,'MIGRATION_140',repeat('a',64),
      '{"api_key":"FORBIDDEN"}'::jsonb
    );
    raise exception 'MIGRATION_140_ENVELOPE_PLAINTEXT_GUARD_NOT_ENFORCED';
  exception when check_violation then
    v_envelope_plaintext_guard:=true;
  end;

  begin
    insert into public.commercial_secret_resolution_dispatch_envelope_requests(
      request_key,idempotency_key,envelope_policy_id,execution_permit_id,
      permit_request_id,permit_decision_id,requested_environment,requested_scope_type,
      requested_scope_key,requested_namespace,requested_capability,requested_operation,
      requested_lifetime_seconds,request_status,correlation_id,requested_by,
      request_hash,request_metadata
    ) values (
      'migration_140:envelope_endpoint:'||v_suffix,
      'migration_140:envelope_endpoint_idem:'||v_suffix,
      v_envelope_policy.id,v_execution_permit.id,v_permit_request.id,v_permit_decision.id,
      'production','platform','platform',v_namespace,'reference_validation',
      'secret_resolution',1,'received',v_corr,'MIGRATION_140',repeat('b',64),
      '{"endpoint":"forbidden.example"}'::jsonb
    );
    raise exception 'MIGRATION_140_ENVELOPE_ENDPOINT_GUARD_NOT_ENFORCED';
  exception when check_violation then
    v_envelope_endpoint_guard:=true;
  end;

  begin
    insert into public.commercial_secret_resolution_dispatch_envelope_requests(
      request_key,idempotency_key,envelope_policy_id,execution_permit_id,
      permit_request_id,permit_decision_id,requested_environment,requested_scope_type,
      requested_scope_key,requested_namespace,requested_capability,requested_operation,
      requested_lifetime_seconds,request_status,correlation_id,requested_by,
      request_hash,request_metadata
    ) values (
      'migration_140:envelope_probe:'||v_suffix,
      'migration_140:envelope_probe_idem:'||v_suffix,
      v_envelope_policy.id,v_execution_permit.id,v_permit_request.id,v_permit_decision.id,
      'production','platform','platform',v_namespace,'reference_validation',
      'secret_resolution',1,'approved',v_corr,'MIGRATION_140',repeat('c',64),
      '{"temporary":true,"guard_probe":true}'::jsonb
    ) returning id into v_probe_envelope_request_id;

    insert into public.commercial_secret_resolution_dispatch_envelope_decisions(
      envelope_request_id,decision_status,decision_code,approved,execution_permit_id,
      selected_backend_binding_id,selected_backend_id,selected_backend_version_id,
      resolved_environment,resolved_scope_type,resolved_scope_key,resolved_namespace,
      resolved_capability,resolved_operation,granted_lifetime_seconds,not_before,
      expires_at,decided_by,decision_reason,decision_hash,decision_metadata
    ) values (
      v_probe_envelope_request_id,'approved','ENVELOPE_METADATA_APPROVED',true,
      v_execution_permit.id,v_binding.id,v_backend.id,v_backend_version.id,
      'production','platform','platform',v_namespace,'reference_validation',
      'secret_resolution',1,clock_timestamp(),clock_timestamp()+interval '1 second',
      'MIGRATION_140','Temporary decision for executable-envelope guard',
      repeat('d',64),'{"temporary":true,"guard_probe":true}'::jsonb
    ) returning id into v_probe_envelope_decision_id;

    insert into public.commercial_secret_resolution_dispatch_envelopes(
      envelope_key,envelope_request_id,envelope_decision_id,execution_permit_id,
      permit_request_id,permit_decision_id,selected_backend_binding_id,
      selected_backend_id,selected_backend_version_id,environment,scope_type,scope_key,
      namespace_code,capability_code,operation_code,envelope_status,not_before,expires_at,
      opaque_reference_contract,metadata_only,executable,dispatchable,transferable,
      queue_publishable,worker_claimable,envelope_hash,envelope_metadata,issued_by
    ) values (
      'migration_140:executable_envelope:'||v_suffix,v_probe_envelope_request_id,
      v_probe_envelope_decision_id,v_execution_permit.id,v_permit_request.id,
      v_permit_decision.id,v_binding.id,v_backend.id,v_backend_version.id,
      'production','platform','platform',v_namespace,'reference_validation',
      'secret_resolution','held',clock_timestamp(),clock_timestamp()+interval '1 second',
      true,true,true,false,false,false,false,repeat('e',64),
      '{"temporary":true,"guard_probe":true}'::jsonb,'MIGRATION_140'
    );
    raise exception 'MIGRATION_140_EXECUTABLE_ENVELOPE_GUARD_NOT_ENFORCED';
  exception when check_violation then
    v_executable_envelope_guard:=true;
  end;

  if not (
    v_envelope_idempotency_conflict_guard
    and v_envelope_policy_guard
    and v_envelope_evaluation_guard
    and v_envelope_decision_guard
    and v_dispatch_envelope_guard
    and v_envelope_cancellation_guard
    and v_envelope_attempt_guard
    and v_envelope_receipt_guard
    and v_envelope_event_guard
    and v_envelope_plaintext_guard
    and v_envelope_endpoint_guard
    and v_executable_envelope_guard
  ) then
    raise exception 'MIGRATION_140_ENVELOPE_GUARD_MATRIX_FAILED';
  end if;

  raise notice
    'MIGRATION_140_DISPATCH_ENVELOPE_LIFECYCLE_CERTIFIED request_count=%, idempotency_count=%, evaluation_count=%, decision_count=%, envelope_count=%, cancellation_count=%, attempt_count=%, receipt_count=%, event_count=%, replay_count=%, decision_status=approved, decision_code=ENVELOPE_METADATA_APPROVED, initial_effective_status=held_metadata_only, expiry_status=expired, final_effective_status=cancelled, attempt_status=blocked, attempt_code=NON_DISPATCHABLE_ENVELOPE_OPERATION_FORBIDDEN, idempotency_conflict_guard=%, policy_guard=%, evaluation_guard=%, decision_guard=%, envelope_guard=%, cancellation_guard=%, attempt_guard=%, receipt_guard=%, event_guard=%, plaintext_guard=%, endpoint_guard=%, executable_envelope_guard=%, metadata_only=true, executable=false, dispatchable=false, transferable=false, queue_publishable=false, worker_claimable=false, dispatch_authorized=false, execution_authorized=false',
    v_envelope_request_count,v_envelope_idempotency_count,v_envelope_evaluation_count,
    v_envelope_decision_count,v_dispatch_envelope_count,v_envelope_cancellation_count,
    v_envelope_attempt_count,v_envelope_receipt_count,v_envelope_event_count,
    v_envelope_replay_count,v_envelope_idempotency_conflict_guard,
    v_envelope_policy_guard,v_envelope_evaluation_guard,v_envelope_decision_guard,
    v_dispatch_envelope_guard,v_envelope_cancellation_guard,v_envelope_attempt_guard,
    v_envelope_receipt_guard,v_envelope_event_guard,v_envelope_plaintext_guard,
    v_envelope_endpoint_guard,v_executable_envelope_guard;


  perform pg_sleep(3.2);

  select * into strict v_permit_read
  from public.commercial_secret_resolution_execution_permit_read_model
  where permit_request_id=v_permit_request.id;

  if v_permit_read.effective_permit_status<>'expired'
     or v_permit_read.metadata_eligibility_current
     or v_permit_read.execution_authorized then
    raise exception
      'MIGRATION_140_EXPIRY_FAILED status=%, eligibility=%, execution_authorized=%',
      v_permit_read.effective_permit_status,
      v_permit_read.metadata_eligibility_current,
      v_permit_read.execution_authorized;
  end if;

  v_permit_revocation :=
    public.revoke_commercial_secret_resolution_execution_permit(
      v_execution_permit.id,
      'migration_140:revocation:'||v_suffix,
      'TEST_REVOCATION',
      'Lifecycle certification revocation after expiry',
      'MIGRATION_140',
      v_corr,
      v_cause,
      jsonb_build_object(
        'temporary',true,
        'certification','MIGRATION_140'
      )
    );

  if v_permit_revocation.execution_permit_id<>v_execution_permit.id
     or v_permit_revocation.revocation_code<>'TEST_REVOCATION'
     or v_permit_revocation.revocation_reason<>
        'Lifecycle certification revocation after expiry' then
    raise exception 'MIGRATION_140_PERMIT_REVOCATION_FAILED';
  end if;

  select * into strict v_permit_read
  from public.commercial_secret_resolution_execution_permit_read_model
  where permit_request_id=v_permit_request.id;

  if v_permit_read.effective_permit_status<>'revoked'
     or v_permit_read.metadata_eligibility_current
     or v_permit_read.execution_authorized
     or v_permit_read.permit_revocation_id<>v_permit_revocation.id
     or v_permit_read.revocation_code<>'TEST_REVOCATION' then
    raise exception
      'MIGRATION_140_REVOKED_EFFECTIVE_STATUS_FAILED status=%, eligibility=%, execution_authorized=%',
      v_permit_read.effective_permit_status,
      v_permit_read.metadata_eligibility_current,
      v_permit_read.execution_authorized;
  end if;

  select count(*) into v_permit_request_count
  from public.commercial_secret_resolution_execution_permit_requests
  where id=v_permit_request.id;

  select count(*) into v_permit_idempotency_count
  from public.commercial_secret_resolution_execution_permit_idempotency
  where permit_request_id=v_permit_request.id;

  select count(*) into v_permit_evaluation_count
  from public.commercial_secret_resolution_execution_permit_evaluations
  where permit_request_id=v_permit_request.id;

  select count(*) into v_permit_decision_count
  from public.commercial_secret_resolution_execution_permit_decisions
  where permit_request_id=v_permit_request.id;

  select count(*) into v_execution_permit_count
  from public.commercial_secret_resolution_execution_permits
  where permit_request_id=v_permit_request.id;

  select count(*) into v_permit_revocation_count
  from public.commercial_secret_resolution_execution_permit_revocations
  where execution_permit_id=v_execution_permit.id;

  select count(*) into v_permit_attempt_count
  from public.commercial_secret_resolution_execution_permit_attempts
  where permit_request_id=v_permit_request.id;

  select count(*) into v_permit_receipt_count
  from public.commercial_secret_resolution_execution_permit_receipts
  where permit_request_id=v_permit_request.id;

  select count(*) into v_permit_event_count
  from public.commercial_secret_resolution_execution_permit_events
  where permit_request_id=v_permit_request.id;

  select replay_count into strict v_permit_replay_count
  from public.commercial_secret_resolution_execution_permit_idempotency
  where permit_request_id=v_permit_request.id;

  if v_permit_request_count<>1
     or v_permit_idempotency_count<>1
     or v_permit_evaluation_count<>11
     or v_permit_decision_count<>1
     or v_execution_permit_count<>1
     or v_permit_revocation_count<>1
     or v_permit_attempt_count<>1
     or v_permit_receipt_count<>7
     or v_permit_event_count<>5
     or v_permit_replay_count<>1 then
    raise exception
      'MIGRATION_140_PERMIT_COUNT_ASSERTION_FAILED request=%, idempotency=%, evaluations=%, decision=%, permit=%, revocation=%, attempt=%, receipts=%, events=%, replay=%',
      v_permit_request_count,
      v_permit_idempotency_count,
      v_permit_evaluation_count,
      v_permit_decision_count,
      v_execution_permit_count,
      v_permit_revocation_count,
      v_permit_attempt_count,
      v_permit_receipt_count,
      v_permit_event_count,
      v_permit_replay_count;
  end if;

  begin
    update public.commercial_secret_resolution_execution_permit_policies
    set policy_version=policy_version+1
    where id=v_permit_policy.id;
    raise exception 'MIGRATION_140_PERMIT_POLICY_GUARD_NOT_ENFORCED';
  exception
    when others then
      if sqlerrm='COMMERCIAL_SECRET_RESOLUTION_EXECUTION_PERMIT_IMMUTABLE' then
        v_permit_policy_guard:=true;
      else
        raise;
      end if;
  end;

  begin
    update public.commercial_secret_resolution_execution_permit_evaluations
    set evaluation_reason='MUTATED'
    where permit_request_id=v_permit_request.id;
    raise exception 'MIGRATION_140_PERMIT_EVALUATION_GUARD_NOT_ENFORCED';
  exception
    when others then
      if sqlerrm='COMMERCIAL_SECRET_RESOLUTION_EXECUTION_PERMIT_IMMUTABLE' then
        v_permit_evaluation_guard:=true;
      else
        raise;
      end if;
  end;

  begin
    update public.commercial_secret_resolution_execution_permit_decisions
    set decision_reason='MUTATED'
    where id=v_permit_decision.id;
    raise exception 'MIGRATION_140_PERMIT_DECISION_GUARD_NOT_ENFORCED';
  exception
    when others then
      if sqlerrm='COMMERCIAL_SECRET_RESOLUTION_EXECUTION_PERMIT_IMMUTABLE' then
        v_permit_decision_guard:=true;
      else
        raise;
      end if;
  end;

  begin
    update public.commercial_secret_resolution_execution_permits
    set permit_status='expired'
    where id=v_execution_permit.id;
    raise exception 'MIGRATION_140_EXECUTION_PERMIT_GUARD_NOT_ENFORCED';
  exception
    when others then
      if sqlerrm='COMMERCIAL_SECRET_RESOLUTION_EXECUTION_PERMIT_IMMUTABLE' then
        v_execution_permit_guard:=true;
      else
        raise;
      end if;
  end;

  begin
    delete from public.commercial_secret_resolution_execution_permit_revocations
    where id=v_permit_revocation.id;
    raise exception 'MIGRATION_140_PERMIT_REVOCATION_GUARD_NOT_ENFORCED';
  exception
    when others then
      if sqlerrm='COMMERCIAL_SECRET_RESOLUTION_EXECUTION_PERMIT_APPEND_ONLY' then
        v_permit_revocation_guard:=true;
      else
        raise;
      end if;
  end;

  begin
    delete from public.commercial_secret_resolution_execution_permit_attempts
    where id=v_permit_attempt.id;
    raise exception 'MIGRATION_140_PERMIT_ATTEMPT_GUARD_NOT_ENFORCED';
  exception
    when others then
      if sqlerrm='COMMERCIAL_SECRET_RESOLUTION_EXECUTION_PERMIT_APPEND_ONLY' then
        v_permit_attempt_guard:=true;
      else
        raise;
      end if;
  end;

  begin
    update public.commercial_secret_resolution_execution_permit_receipts
    set receipt_message='MUTATED'
    where permit_request_id=v_permit_request.id;
    raise exception 'MIGRATION_140_PERMIT_RECEIPT_GUARD_NOT_ENFORCED';
  exception
    when others then
      if sqlerrm='COMMERCIAL_SECRET_RESOLUTION_EXECUTION_PERMIT_APPEND_ONLY' then
        v_permit_receipt_guard:=true;
      else
        raise;
      end if;
  end;

  begin
    delete from public.commercial_secret_resolution_execution_permit_events
    where permit_request_id=v_permit_request.id;
    raise exception 'MIGRATION_140_PERMIT_EVENT_GUARD_NOT_ENFORCED';
  exception
    when others then
      if sqlerrm='COMMERCIAL_SECRET_RESOLUTION_EXECUTION_PERMIT_APPEND_ONLY' then
        v_permit_event_guard:=true;
      else
        raise;
      end if;
  end;

  begin
    insert into public.commercial_secret_resolution_execution_permit_requests(
      request_key,idempotency_key,permit_policy_id,
      handoff_request_id,handoff_decision_id,handoff_manifest_id,
      authorization_request_id,authorization_decision_id,
      requested_environment,requested_scope_type,requested_scope_key,
      requested_namespace,requested_capability,requested_operation,
      requested_lifetime_seconds,request_status,correlation_id,requested_by,
      request_hash,request_metadata
    ) values (
      'migration_140:permit_plaintext:'||v_suffix,
      'migration_140:permit_plaintext_idempotency:'||v_suffix,
      v_permit_policy.id,
      v_handoff_request.id,v_handoff_decision.id,v_handoff_manifest.id,
      v_authorization_request.id,v_authorization_decision.id,
      'production','platform','platform',v_namespace,
      'reference_validation','secret_resolution',3,'received',
      v_corr,'MIGRATION_140',repeat('d',64),
      '{"api_key":"FORBIDDEN"}'::jsonb
    );
    raise exception 'MIGRATION_140_PERMIT_PLAINTEXT_GUARD_NOT_ENFORCED';
  exception
    when check_violation then
      v_permit_plaintext_guard:=true;
  end;

  begin
    insert into public.commercial_secret_resolution_execution_permit_requests(
      request_key,idempotency_key,permit_policy_id,
      handoff_request_id,handoff_decision_id,handoff_manifest_id,
      authorization_request_id,authorization_decision_id,
      requested_environment,requested_scope_type,requested_scope_key,
      requested_namespace,requested_capability,requested_operation,
      requested_lifetime_seconds,request_status,correlation_id,requested_by,
      request_hash,request_metadata
    ) values (
      'migration_140:permit_endpoint:'||v_suffix,
      'migration_140:permit_endpoint_idempotency:'||v_suffix,
      v_permit_policy.id,
      v_handoff_request.id,v_handoff_decision.id,v_handoff_manifest.id,
      v_authorization_request.id,v_authorization_decision.id,
      'production','platform','platform',v_namespace,
      'reference_validation','secret_resolution',3,'received',
      v_corr,'MIGRATION_140',repeat('e',64),
      '{"endpoint":"forbidden.example"}'::jsonb
    );
    raise exception 'MIGRATION_140_PERMIT_ENDPOINT_GUARD_NOT_ENFORCED';
  exception
    when check_violation then
      v_permit_endpoint_guard:=true;
  end;

  begin
    insert into public.commercial_secret_resolution_execution_permit_policies(
      policy_code,environment,policy_status,policy_version,
      permit_execution_enabled,created_by,approved_by,approved_at,
      policy_metadata
    ) values (
      'commercial:secret_resolution_execution_permit:active_probe:'||v_suffix,
      'test','approved',1,true,
      'MIGRATION_140','MIGRATION_140',clock_timestamp(),
      '{"temporary":true}'::jsonb
    );
    raise exception 'MIGRATION_140_ACTIVE_POLICY_GUARD_NOT_ENFORCED';
  exception
    when check_violation then
      v_active_policy_guard:=true;
  end;

  if not (
    v_permit_idempotency_conflict_guard
    and v_permit_policy_guard
    and v_permit_evaluation_guard
    and v_permit_decision_guard
    and v_execution_permit_guard
    and v_permit_revocation_guard
    and v_permit_attempt_guard
    and v_permit_receipt_guard
    and v_permit_event_guard
    and v_permit_plaintext_guard
    and v_permit_endpoint_guard
    and v_active_policy_guard
  ) then
    raise exception 'MIGRATION_140_PERMIT_GUARD_MATRIX_FAILED';
  end if;

  raise notice
    'MIGRATION_140_PERMIT_LIFECYCLE_CERTIFIED request_count=%, idempotency_count=%, evaluation_count=%, decision_count=%, permit_count=%, revocation_count=%, attempt_count=%, receipt_count=%, event_count=%, replay_count=%, decision_status=approved, decision_code=PERMIT_METADATA_APPROVED, initial_effective_status=eligible_metadata_only, expiry_status=expired, final_effective_status=revoked, attempt_status=blocked, attempt_code=NON_EXECUTABLE_PERMIT_OPERATION_FORBIDDEN, idempotency_conflict_guard=%, policy_guard=%, evaluation_guard=%, decision_guard=%, permit_guard=%, revocation_guard=%, attempt_guard=%, receipt_guard=%, event_guard=%, plaintext_guard=%, endpoint_guard=%, active_policy_guard=%, metadata_only=true, executable=false, revocable=true, bearer_credential=false, transferable=false, execution_authorized=false',
    v_permit_request_count,
    v_permit_idempotency_count,
    v_permit_evaluation_count,
    v_permit_decision_count,
    v_execution_permit_count,
    v_permit_revocation_count,
    v_permit_attempt_count,
    v_permit_receipt_count,
    v_permit_event_count,
    v_permit_replay_count,
    v_permit_idempotency_conflict_guard,
    v_permit_policy_guard,
    v_permit_evaluation_guard,
    v_permit_decision_guard,
    v_execution_permit_guard,
    v_permit_revocation_guard,
    v_permit_attempt_guard,
    v_permit_receipt_guard,
    v_permit_event_guard,
    v_permit_plaintext_guard,
    v_permit_endpoint_guard,
    v_active_policy_guard;

  -- ===========================================================================
  -- 13. HANDOFF READ MODEL
  -- ===========================================================================

  select * into strict v_read
  from public.commercial_secret_reference_handoff_read_model
  where handoff_request_id=v_handoff_request.id;

  if v_read.request_status<>'accepted'
     or v_read.decision_status<>'accepted'
     or v_read.decision_code<>'HANDOFF_ACCEPTED'
     or not v_read.accepted
     or v_read.manifest_status<>'held'
     or not v_read.opaque_reference_contract
     or not v_read.metadata_only
     or v_read.executable
     or v_read.dispatch_allowed
     or v_read.activation_allowed
     or v_read.backend_contact_allowed
     or v_read.secret_resolution_allowed
     or v_read.network_access_allowed
     or v_read.evaluation_count<>10
     or v_read.attempt_count<>1
     or v_read.receipt_count<>6
     or v_read.event_count<>4
     or v_read.replay_count<>1 then
    raise exception
      'MIGRATION_140_READ_MODEL_FAILED evaluations=%, attempts=%, receipts=%, events=%, replay=%',
      v_read.evaluation_count,
      v_read.attempt_count,
      v_read.receipt_count,
      v_read.event_count,
      v_read.replay_count;
  end if;

  -- ===========================================================================
  -- 11. EXACT COUNTS
  -- ===========================================================================

  select count(*) into v_backend_count
  from public.commercial_secret_backends
  where id=v_backend.id;

  select count(*) into v_version_count
  from public.commercial_secret_backend_versions
  where secret_backend_id=v_backend.id;

  select count(*) into v_capability_count
  from public.commercial_secret_backend_capabilities
  where secret_backend_version_id=v_backend_version.id;

  select count(*) into v_binding_count
  from public.commercial_secret_backend_bindings
  where id=v_binding.id;

  select count(*) into v_gateway_request_count
  from public.commercial_secret_reference_gateway_requests
  where id=v_gateway_request.id;

  select count(*) into v_gateway_decision_count
  from public.commercial_secret_reference_gateway_decisions
  where id=v_gateway_decision.id;

  select count(*) into v_authorization_request_count
  from public.commercial_secret_reference_authorization_requests
  where id=v_authorization_request.id;

  select count(*) into v_authorization_evaluation_count
  from public.commercial_secret_reference_authorization_evaluations
  where authorization_request_id=v_authorization_request.id;

  select count(*) into v_authorization_decision_count
  from public.commercial_secret_reference_authorization_decisions
  where id=v_authorization_decision.id;

  select count(*) into v_handoff_request_count
  from public.commercial_secret_reference_handoff_requests
  where id=v_handoff_request.id;

  select count(*) into v_handoff_idempotency_count
  from public.commercial_secret_reference_handoff_idempotency
  where handoff_request_id=v_handoff_request.id;

  select count(*) into v_handoff_evaluation_count
  from public.commercial_secret_reference_handoff_evaluations
  where handoff_request_id=v_handoff_request.id;

  select count(*) into v_handoff_decision_count
  from public.commercial_secret_reference_handoff_decisions
  where handoff_request_id=v_handoff_request.id;

  select count(*) into v_handoff_manifest_count
  from public.commercial_secret_reference_handoff_manifests
  where handoff_request_id=v_handoff_request.id;

  select count(*) into v_handoff_attempt_count
  from public.commercial_secret_reference_handoff_attempts
  where handoff_request_id=v_handoff_request.id;

  select count(*) into v_handoff_receipt_count
  from public.commercial_secret_reference_handoff_receipts
  where handoff_request_id=v_handoff_request.id;

  select count(*) into v_handoff_event_count
  from public.commercial_secret_reference_handoff_events
  where handoff_request_id=v_handoff_request.id;

  select replay_count into strict v_handoff_replay_count
  from public.commercial_secret_reference_handoff_idempotency
  where handoff_request_id=v_handoff_request.id;

  if v_backend_count<>1
     or v_version_count<>1
     or v_capability_count<>5
     or v_binding_count<>1
     or v_gateway_request_count<>1
     or v_gateway_decision_count<>1
     or v_authorization_request_count<>1
     or v_authorization_evaluation_count<>2
     or v_authorization_decision_count<>1
     or v_handoff_request_count<>1
     or v_handoff_idempotency_count<>1
     or v_handoff_evaluation_count<>10
     or v_handoff_decision_count<>1
     or v_handoff_manifest_count<>1
     or v_handoff_attempt_count<>1
     or v_handoff_receipt_count<>6
     or v_handoff_event_count<>4
     or v_handoff_replay_count<>1 then
    raise exception
      'MIGRATION_140_COUNT_ASSERTION_FAILED backend=%, version=%, capabilities=%, binding=%, gateway_request=%, gateway_decision=%, authorization_request=%, authorization_evaluations=%, authorization_decision=%, handoff_request=%, handoff_idempotency=%, handoff_evaluations=%, handoff_decision=%, handoff_manifest=%, handoff_attempt=%, handoff_receipts=%, handoff_events=%, replay=%',
      v_backend_count,
      v_version_count,
      v_capability_count,
      v_binding_count,
      v_gateway_request_count,
      v_gateway_decision_count,
      v_authorization_request_count,
      v_authorization_evaluation_count,
      v_authorization_decision_count,
      v_handoff_request_count,
      v_handoff_idempotency_count,
      v_handoff_evaluation_count,
      v_handoff_decision_count,
      v_handoff_manifest_count,
      v_handoff_attempt_count,
      v_handoff_receipt_count,
      v_handoff_event_count,
      v_handoff_replay_count;
  end if;

  -- ===========================================================================
  -- 14. IMMUTABILITY AND APPEND-ONLY GUARDS
  -- ===========================================================================

  begin
    update public.commercial_secret_reference_handoff_policies
    set policy_version=policy_version+1
    where id=v_handoff_policy.id;

    raise exception 'MIGRATION_140_POLICY_GUARD_NOT_ENFORCED';
  exception
    when others then
      if sqlerrm='COMMERCIAL_SECRET_REFERENCE_HANDOFF_IMMUTABLE' then
        v_policy_guard:=true;
      else
        raise;
      end if;
  end;

  begin
    update public.commercial_secret_reference_handoff_evaluations
    set evaluation_reason='MUTATED'
    where handoff_request_id=v_handoff_request.id;

    raise exception 'MIGRATION_140_EVALUATION_GUARD_NOT_ENFORCED';
  exception
    when others then
      if sqlerrm='COMMERCIAL_SECRET_REFERENCE_HANDOFF_IMMUTABLE' then
        v_evaluation_guard:=true;
      else
        raise;
      end if;
  end;

  begin
    update public.commercial_secret_reference_handoff_decisions
    set decision_reason='MUTATED'
    where id=v_handoff_decision.id;

    raise exception 'MIGRATION_140_DECISION_GUARD_NOT_ENFORCED';
  exception
    when others then
      if sqlerrm='COMMERCIAL_SECRET_REFERENCE_HANDOFF_IMMUTABLE' then
        v_decision_guard:=true;
      else
        raise;
      end if;
  end;

  begin
    update public.commercial_secret_reference_handoff_manifests
    set manifest_status='cancelled'
    where id=v_handoff_manifest.id;

    raise exception 'MIGRATION_140_MANIFEST_GUARD_NOT_ENFORCED';
  exception
    when others then
      if sqlerrm='COMMERCIAL_SECRET_REFERENCE_HANDOFF_IMMUTABLE' then
        v_manifest_guard:=true;
      else
        raise;
      end if;
  end;

  begin
    delete from public.commercial_secret_reference_handoff_attempts
    where id=v_handoff_attempt.id;

    raise exception 'MIGRATION_140_ATTEMPT_GUARD_NOT_ENFORCED';
  exception
    when others then
      if sqlerrm='COMMERCIAL_SECRET_REFERENCE_HANDOFF_APPEND_ONLY' then
        v_attempt_guard:=true;
      else
        raise;
      end if;
  end;

  begin
    update public.commercial_secret_reference_handoff_receipts
    set receipt_message='MUTATED'
    where handoff_request_id=v_handoff_request.id;

    raise exception 'MIGRATION_140_RECEIPT_GUARD_NOT_ENFORCED';
  exception
    when others then
      if sqlerrm='COMMERCIAL_SECRET_REFERENCE_HANDOFF_APPEND_ONLY' then
        v_receipt_guard:=true;
      else
        raise;
      end if;
  end;

  begin
    delete from public.commercial_secret_reference_handoff_events
    where handoff_request_id=v_handoff_request.id;

    raise exception 'MIGRATION_140_EVENT_GUARD_NOT_ENFORCED';
  exception
    when others then
      if sqlerrm='COMMERCIAL_SECRET_REFERENCE_HANDOFF_APPEND_ONLY' then
        v_event_guard:=true;
      else
        raise;
      end if;
  end;

  -- ===========================================================================
  -- 13. PLAINTEXT, ENDPOINT AND EXECUTABLE-MANIFEST GUARDS
  -- ===========================================================================

  begin
    insert into public.commercial_secret_reference_handoff_requests(
      request_key,
      idempotency_key,
      handoff_policy_id,
      authorization_request_id,
      authorization_decision_id,
      gateway_request_id,
      gateway_decision_id,
      requested_environment,
      requested_scope_type,
      requested_scope_key,
      requested_namespace,
      requested_capability,
      request_status,
      correlation_id,
      requested_by,
      request_hash,
      request_metadata
    ) values (
      'migration_140:plaintext:'||v_suffix,
      'migration_140:plaintext_idempotency:'||v_suffix,
      v_handoff_policy.id,
      v_authorization_request.id,
      v_authorization_decision.id,
      v_gateway_request.id,
      v_gateway_decision.id,
      'production',
      'platform',
      'platform',
      v_namespace,
      'reference_validation',
      'received',
      v_corr,
      'MIGRATION_140',
      repeat('a',64),
      '{"api_key":"FORBIDDEN"}'::jsonb
    );

    raise exception 'MIGRATION_140_PLAINTEXT_GUARD_NOT_ENFORCED';
  exception
    when check_violation then
      v_plaintext_guard:=true;
  end;

  begin
    insert into public.commercial_secret_reference_handoff_requests(
      request_key,
      idempotency_key,
      handoff_policy_id,
      authorization_request_id,
      authorization_decision_id,
      gateway_request_id,
      gateway_decision_id,
      requested_environment,
      requested_scope_type,
      requested_scope_key,
      requested_namespace,
      requested_capability,
      request_status,
      correlation_id,
      requested_by,
      request_hash,
      request_metadata
    ) values (
      'migration_140:endpoint:'||v_suffix,
      'migration_140:endpoint_idempotency:'||v_suffix,
      v_handoff_policy.id,
      v_authorization_request.id,
      v_authorization_decision.id,
      v_gateway_request.id,
      v_gateway_decision.id,
      'production',
      'platform',
      'platform',
      v_namespace,
      'reference_validation',
      'received',
      v_corr,
      'MIGRATION_140',
      repeat('b',64),
      '{"endpoint":"forbidden.example"}'::jsonb
    );

    raise exception 'MIGRATION_140_ENDPOINT_GUARD_NOT_ENFORCED';
  exception
    when check_violation then
      v_endpoint_guard:=true;
  end;

  begin
    insert into public.commercial_secret_reference_handoff_requests(
      request_key,
      idempotency_key,
      handoff_policy_id,
      authorization_request_id,
      authorization_decision_id,
      gateway_request_id,
      gateway_decision_id,
      requested_environment,
      requested_scope_type,
      requested_scope_key,
      requested_namespace,
      requested_capability,
      request_status,
      correlation_id,
      requested_by,
      request_hash,
      request_metadata
    ) values (
      'migration_140:executable_probe:'||v_suffix,
      'migration_140:executable_probe_idempotency:'||v_suffix,
      v_handoff_policy.id,
      v_authorization_request.id,
      v_authorization_decision.id,
      v_gateway_request.id,
      v_gateway_decision.id,
      'production',
      'platform',
      'platform',
      v_namespace,
      'reference_validation',
      'accepted',
      v_corr,
      'MIGRATION_140',
      repeat('c',64),
      '{"temporary":true,"guard_probe":true}'::jsonb
    ) returning id into v_probe_handoff_request_id;

    insert into public.commercial_secret_reference_handoff_decisions(
      handoff_request_id,
      decision_status,
      decision_code,
      accepted,
      authorization_decision_id,
      selected_backend_binding_id,
      selected_backend_id,
      selected_backend_version_id,
      resolved_environment,
      resolved_scope_type,
      resolved_scope_key,
      resolved_namespace,
      resolved_capability,
      decided_by,
      decision_reason,
      decision_hash,
      decision_metadata
    ) values (
      v_probe_handoff_request_id,
      'accepted',
      'HANDOFF_ACCEPTED',
      true,
      v_authorization_decision.id,
      v_binding.id,
      v_backend.id,
      v_backend_version.id,
      'production',
      'platform',
      'platform',
      v_namespace,
      'reference_validation',
      'MIGRATION_140',
      'Temporary passive decision for executable-manifest guard',
      repeat('d',64),
      '{"passive_handoff_only":true,"guard_probe":true}'::jsonb
    ) returning id into v_probe_handoff_decision_id;

    insert into public.commercial_secret_reference_handoff_manifests(
      manifest_key,
      handoff_request_id,
      handoff_decision_id,
      authorization_request_id,
      authorization_decision_id,
      selected_backend_binding_id,
      selected_backend_id,
      selected_backend_version_id,
      environment,
      scope_type,
      scope_key,
      namespace_code,
      capability_code,
      manifest_status,
      opaque_reference_contract,
      metadata_only,
      executable,
      dispatch_allowed,
      activation_allowed,
      backend_contact_allowed,
      secret_resolution_allowed,
      network_access_allowed,
      manifest_hash,
      manifest_metadata,
      created_by
    ) values (
      'migration_140:executable:'||v_suffix,
      v_probe_handoff_request_id,
      v_probe_handoff_decision_id,
      v_authorization_request.id,
      v_authorization_decision.id,
      v_binding.id,
      v_backend.id,
      v_backend_version.id,
      'production',
      'platform',
      'platform',
      v_namespace,
      'reference_validation',
      'held',
      true,
      true,
      true,
      false,
      false,
      false,
      false,
      false,
      repeat('e',64),
      '{"temporary":true,"guard_probe":true}'::jsonb,
      'MIGRATION_140'
    );

    raise exception 'MIGRATION_140_EXECUTABLE_MANIFEST_GUARD_NOT_ENFORCED';
  exception
    when check_violation then
      v_executable_manifest_guard:=true;
  end;

  if not (
    v_idempotency_conflict_guard
    and v_policy_guard
    and v_evaluation_guard
    and v_decision_guard
    and v_manifest_guard
    and v_attempt_guard
    and v_receipt_guard
    and v_event_guard
    and v_plaintext_guard
    and v_endpoint_guard
    and v_executable_manifest_guard
  ) then
    raise exception 'MIGRATION_140_GUARD_MATRIX_FAILED';
  end if;

  -- ===========================================================================
  -- 16. ECONOMIC/RUNTIME NON-MUTATION
  -- ===========================================================================

  select count(*) into v_purchase_after
  from public.commercial_purchases;

  select count(*) into v_checkout_after
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

  if v_purchase_after<>v_purchase_before
     or v_checkout_after<>v_checkout_before
     or v_provider_request_after<>v_provider_request_before
     or v_callback_after<>v_callback_before
     or v_reconciliation_after<>v_reconciliation_before
     or v_wallet_after<>v_wallet_before
     or v_ledger_after<>v_ledger_before
     or v_outbox_after<>v_outbox_before then
    raise exception 'MIGRATION_140_ECONOMIC_NON_MUTATION_FAILED';
  end if;

  -- ===========================================================================
  -- 17. FINAL CERTIFICATION
  -- ===========================================================================

  raise notice
    'MIGRATION_140_CERTIFIED backend_count=%, version_count=%, capability_count=%, binding_count=%, gateway_request_count=%, gateway_decision_count=%, authorization_request_count=%, authorization_evaluation_count=%, authorization_decision_count=%, handoff_request_count=%, handoff_idempotency_count=%, handoff_evaluation_count=%, handoff_decision_count=%, handoff_manifest_count=%, handoff_attempt_count=%, handoff_receipt_count=%, handoff_event_count=%, replay_count=%, authorization_status=authorized, authorization_code=AUTHORIZED, handoff_status=accepted, handoff_code=HANDOFF_ACCEPTED, manifest_status=held, attempt_status=blocked, attempt_code=PASSIVE_HANDOFF_EXECUTION_FORBIDDEN, idempotency_conflict_guard=%, policy_guard=%, evaluation_guard=%, decision_guard=%, manifest_guard=%, attempt_guard=%, receipt_guard=%, event_guard=%, plaintext_guard=%, endpoint_guard=%, executable_manifest_guard=%, automatic_dispatch_enabled=false, activation_enabled=false, endpoint_discovery_enabled=false, backend_probe_enabled=false, backend_contact_enabled=false, backend_authentication_enabled=false, secret_lookup_enabled=false, secret_resolution_enabled=false, secret_decryption_enabled=false, credential_material_loading_enabled=false, credential_delivery_enabled=false, network_access_enabled=false, opaque_references_only=true, metadata_only=true, executable=false, purchase_delta=0, checkout_delta=0, provider_request_delta=0, callback_delta=0, reconciliation_delta=0, wallet_delta=0, ledger_delta=0, outbox_delta=0, rollback_required=true',
    v_backend_count,
    v_version_count,
    v_capability_count,
    v_binding_count,
    v_gateway_request_count,
    v_gateway_decision_count,
    v_authorization_request_count,
    v_authorization_evaluation_count,
    v_authorization_decision_count,
    v_handoff_request_count,
    v_handoff_idempotency_count,
    v_handoff_evaluation_count,
    v_handoff_decision_count,
    v_handoff_manifest_count,
    v_handoff_attempt_count,
    v_handoff_receipt_count,
    v_handoff_event_count,
    v_handoff_replay_count,
    v_idempotency_conflict_guard,
    v_policy_guard,
    v_evaluation_guard,
    v_decision_guard,
    v_manifest_guard,
    v_attempt_guard,
    v_receipt_guard,
    v_event_guard,
    v_plaintext_guard,
    v_endpoint_guard,
    v_executable_manifest_guard;
end
$$;

rollback;

\echo ''
\echo 'MIGRATION_140_TRANSACTION_ROLLED_BACK'
\echo 'No temporary backend, capability, binding, gateway object, authorization object, handoff object, execution-permit object, dispatch-envelope object, dispatch-admission ticket, cancellation, revocation, policy change, purchase, checkout, wallet, ledger or outbox mutation was persisted.'
