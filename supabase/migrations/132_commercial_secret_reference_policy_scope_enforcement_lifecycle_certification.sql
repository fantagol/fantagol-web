-- =============================================================================
-- FANTAGOL
-- Migration: 132_commercial_secret_reference_policy_scope_enforcement_lifecycle_certification.sql
-- Milestone: Commercial Secret Reference Policy & Scope Enforcement
--
-- Purpose:
--   Transactionally certify migration 131 through a temporary validated secret
--   backend chain and a passive gateway decision produced by migrations 127-130.
--
-- Certified paths:
--   1. AUTHORIZED
--   2. NO_SCOPE_RULE -> HELD
--   3. INVALID_SCOPE -> BLOCKED
--   4. NAMESPACE_NOT_OWNED -> BLOCKED
--   5. idempotent replay
--   6. idempotency conflict rejection
--   7. read-model integrity
--   8. immutable / append-only guards
--   9. plaintext, endpoint and active-posture guards
--  10. zero commercial/economic/runtime mutation
--
-- The certification ends with ROLLBACK.
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
  v_orchestrator_policy public.commercial_secret_resolution_policies;
  v_gateway_policy public.commercial_secret_reference_gateway_policies;
  v_authorization_policy public.commercial_secret_reference_authorization_policies;

  v_backend public.commercial_secret_backends;
  v_backend_version public.commercial_secret_backend_versions;
  v_binding public.commercial_secret_backend_bindings;
  v_gateway_request public.commercial_secret_reference_gateway_requests;
  v_gateway_decision public.commercial_secret_reference_gateway_decisions;

  v_authorized_request public.commercial_secret_reference_authorization_requests;
  v_authorized_replay public.commercial_secret_reference_authorization_requests;
  v_authorized_decision public.commercial_secret_reference_authorization_decisions;

  v_held_request public.commercial_secret_reference_authorization_requests;
  v_held_decision public.commercial_secret_reference_authorization_decisions;

  v_invalid_request public.commercial_secret_reference_authorization_requests;
  v_invalid_decision public.commercial_secret_reference_authorization_decisions;

  v_namespace_request public.commercial_secret_reference_authorization_requests;
  v_namespace_decision public.commercial_secret_reference_authorization_decisions;

  v_invalid_rule public.commercial_secret_reference_scope_rules;
  v_namespace_rule public.commercial_secret_reference_scope_rules;

  v_read public.commercial_secret_reference_authorization_read_model;

  v_suffix text := lower(substr(replace(gen_random_uuid()::text,'-',''),1,12));
  v_backend_code text;
  v_backend_name text;
  v_namespace text;
  v_wrong_namespace text;
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
  v_rule_guard boolean := false;
  v_evaluation_guard boolean := false;
  v_decision_guard boolean := false;
  v_receipt_guard boolean := false;
  v_event_guard boolean := false;
  v_plaintext_guard boolean := false;
  v_endpoint_guard boolean := false;
  v_active_decision_guard boolean := false;

  v_backend_count bigint;
  v_version_count bigint;
  v_capability_count bigint;
  v_binding_count bigint;
  v_gateway_request_count bigint;
  v_gateway_decision_count bigint;

  v_auth_request_count bigint;
  v_auth_evaluation_count bigint;
  v_auth_decision_count bigint;
  v_auth_receipt_count bigint;
  v_auth_event_count bigint;

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
  -- 1. DEPENDENCIES AND PASSIVE POLICY POSTURE
  -- ===========================================================================

  if to_regclass('public.commercial_secret_reference_authorization_policies') is null
     or to_regclass('public.commercial_secret_reference_scope_rules') is null
     or to_regclass('public.commercial_secret_reference_authorization_requests') is null
     or to_regclass('public.commercial_secret_reference_authorization_evaluations') is null
     or to_regclass('public.commercial_secret_reference_authorization_decisions') is null
     or to_regclass('public.commercial_secret_reference_authorization_receipts') is null
     or to_regclass('public.commercial_secret_reference_authorization_events') is null
     or to_regclass('public.commercial_secret_reference_authorization_read_model') is null then
    raise exception 'MIGRATION_132_REQUIRES_MIGRATION_131_OBJECTS';
  end if;

  if to_regprocedure(
       'public.enqueue_commercial_secret_reference_authorization_request(text,text,uuid,uuid,text,text,text,text,text,uuid,uuid,jsonb)'
     ) is null
     or to_regprocedure(
       'public.evaluate_commercial_secret_reference_authorization_request(uuid,text)'
     ) is null then
    raise exception 'MIGRATION_132_REQUIRES_MIGRATION_131_FUNCTIONS';
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

  select * into strict v_authorization_policy
  from public.commercial_secret_reference_authorization_policies
  where policy_code='commercial:secret_reference_authorization:v1'
    and environment='production'
    and policy_status='approved';

  if not (
    v_authorization_policy.intake_enabled
    and v_authorization_policy.policy_evaluation_enabled
    and v_authorization_policy.scope_enforcement_enabled
    and v_authorization_policy.namespace_ownership_enabled
    and v_authorization_policy.capability_enforcement_enabled
    and v_authorization_policy.backend_trust_enforcement_enabled
    and v_authorization_policy.binding_validation_enforcement_enabled
    and v_authorization_policy.contract_validation_enabled
    and v_authorization_policy.decision_recording_enabled
  ) then
    raise exception 'MIGRATION_132_AUTHORIZATION_CAPABILITY_MATRIX_DISABLED';
  end if;

  if v_authorization_policy.automatic_dispatch_enabled
     or v_authorization_policy.endpoint_discovery_enabled
     or v_authorization_policy.backend_probe_enabled
     or v_authorization_policy.backend_contact_enabled
     or v_authorization_policy.backend_authentication_enabled
     or v_authorization_policy.secret_lookup_enabled
     or v_authorization_policy.secret_resolution_enabled
     or v_authorization_policy.secret_decryption_enabled
     or v_authorization_policy.credential_material_loading_enabled
     or v_authorization_policy.credential_delivery_enabled
     or v_authorization_policy.network_access_enabled then
    raise exception 'MIGRATION_132_UNSAFE_AUTHORIZATION_POLICY';
  end if;

  -- ===========================================================================
  -- 2. ECONOMIC/RUNTIME BASELINES
  -- ===========================================================================

  select count(*) into v_purchase_before from public.commercial_purchases;
  select count(*) into v_checkout_before from public.commercial_checkout_sessions;
  select count(*) into v_provider_request_before from public.commercial_checkout_provider_requests;
  select count(*) into v_callback_before from public.commercial_checkout_callbacks;
  select count(*) into v_reconciliation_before from public.commercial_checkout_reconciliation_observations;
  select count(*) into v_wallet_before from public.commercial_wallets;
  select count(*) into v_ledger_before from public.commercial_ledger;
  select count(*) into v_outbox_before from public.commercial_purchase_runtime_outbox;

  -- ===========================================================================
  -- 3. TEMPORARY VALIDATED BACKEND + GATEWAY CHAIN
  -- ===========================================================================

  v_backend_code := 'migration_132_backend_' || v_suffix;
  v_backend_name := 'Migration 132 Passive Backend ' || upper(v_suffix);
  v_namespace := 'migration_132:opaque:' || v_suffix;
  v_wrong_namespace := 'migration_132:foreign:' || v_suffix;
  v_binding_key := 'migration_132:binding:' || v_suffix;

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
    'MIGRATION_132',
    v_corr,
    jsonb_build_object('temporary',true,'certification','MIGRATION_132')
  );

  v_backend_version := public.register_commercial_secret_backend_version(
    v_backend.id,
    1,
    'FantaGol Authorization Lifecycle Contract',
    '1.0.0',
    v_contract_hash,
    v_reference_schema_hash,
    true,true,true,true,
    'MIGRATION_132',
    v_corr,
    jsonb_build_object('temporary',true,'passive_only',true)
  );

  perform public.register_commercial_secret_backend_capability(
    v_backend_version.id,'reference_validation','reference_validation',
    'MIGRATION_132',v_corr,'{"temporary":true,"offline_only":true}'::jsonb
  );
  perform public.register_commercial_secret_backend_capability(
    v_backend_version.id,'versioned_references','version_metadata',
    'MIGRATION_132',v_corr,'{"temporary":true,"offline_only":true}'::jsonb
  );
  perform public.register_commercial_secret_backend_capability(
    v_backend_version.id,'rotation_metadata','rotation_metadata',
    'MIGRATION_132',v_corr,'{"temporary":true,"offline_only":true}'::jsonb
  );
  perform public.register_commercial_secret_backend_capability(
    v_backend_version.id,'expiry_metadata','expiry_metadata',
    'MIGRATION_132',v_corr,'{"temporary":true,"offline_only":true}'::jsonb
  );
  perform public.register_commercial_secret_backend_capability(
    v_backend_version.id,'scope_metadata','scope_metadata',
    'MIGRATION_132',v_corr,'{"temporary":true,"offline_only":true}'::jsonb
  );

  v_backend_version := public.validate_commercial_secret_backend_version(
    v_backend_version.id,'MIGRATION_132',v_corr
  );

  select * into strict v_backend
  from public.commercial_secret_backends
  where id=v_backend.id;

  v_binding := public.register_commercial_secret_backend_binding(
    v_binding_key,
    v_backend.id,
    v_backend_version.id,
    null,
    v_orchestrator_policy.id,
    'platform',
    100,
    v_namespace,
    'MIGRATION_132',
    v_corr,
    jsonb_build_object('temporary',true,'passive_only',true)
  );

  v_binding := public.validate_commercial_secret_backend_binding(
    v_binding.id,'MIGRATION_132',v_corr
  );

  v_gateway_request := public.enqueue_commercial_secret_reference_gateway_request(
    'migration_132:gateway_request:'||v_suffix,
    'migration_132:gateway_idempotency:'||v_suffix,
    null,
    null,
    'production',
    v_namespace,
    'reference_validation',
    'platform',
    'MIGRATION_132',
    v_corr,
    v_cause,
    jsonb_build_object('temporary',true,'opaque_references_only',true)
  );

  v_gateway_decision := public.evaluate_commercial_secret_reference_gateway_request(
    v_gateway_request.id,'MIGRATION_132'
  );

  if v_gateway_decision.decision_status<>'accepted'
     or v_gateway_decision.decision_code<>'ROUTE_METADATA_ACCEPTED'
     or v_gateway_decision.selected_backend_binding_id<>v_binding.id
     or v_gateway_decision.selected_backend_id<>v_backend.id
     or v_gateway_decision.selected_backend_version_id<>v_backend_version.id
     or not v_gateway_decision.capability_available then
    raise exception 'MIGRATION_132_GATEWAY_PREREQUISITE_FAILED';
  end if;

  raise notice
    'MIGRATION_132_TEMPORARY_CHAIN_CREATED backend_id=%, version_id=%, binding_id=%, gateway_request_id=%, gateway_decision_id=%',
    v_backend.id,v_backend_version.id,v_binding.id,
    v_gateway_request.id,v_gateway_decision.id;

  -- ===========================================================================
  -- 4. AUTHORIZED PATH + IDEMPOTENT REPLAY
  -- ===========================================================================

  v_authorized_request :=
    public.enqueue_commercial_secret_reference_authorization_request(
      'migration_132:authorized:'||v_suffix,
      'migration_132:authorized_idem:'||v_suffix,
      v_gateway_request.id,
      v_gateway_decision.id,
      'platform',
      'platform',
      v_namespace,
      'reference_validation',
      'MIGRATION_132',
      v_corr,
      v_cause,
      jsonb_build_object('scenario','AUTHORIZED','opaque_references_only',true)
    );

  v_authorized_replay :=
    public.enqueue_commercial_secret_reference_authorization_request(
      'migration_132:authorized:'||v_suffix,
      'migration_132:authorized_idem:'||v_suffix,
      v_gateway_request.id,
      v_gateway_decision.id,
      'platform',
      'platform',
      v_namespace,
      'reference_validation',
      'MIGRATION_132',
      v_corr,
      v_cause,
      jsonb_build_object('scenario','AUTHORIZED','opaque_references_only',true)
    );

  if v_authorized_replay.id<>v_authorized_request.id then
    raise exception 'MIGRATION_132_IDEMPOTENT_REPLAY_CREATED_DUPLICATE';
  end if;

  begin
    perform public.enqueue_commercial_secret_reference_authorization_request(
      'migration_132:authorized:'||v_suffix,
      'migration_132:authorized_idem:'||v_suffix,
      v_gateway_request.id,
      v_gateway_decision.id,
      'platform',
      'platform',
      v_namespace,
      'scope_metadata',
      'MIGRATION_132',
      v_corr,
      v_cause,
      jsonb_build_object('scenario','CONFLICT','opaque_references_only',true)
    );
    raise exception 'MIGRATION_132_IDEMPOTENCY_CONFLICT_NOT_ENFORCED';
  exception
    when others then
      if sqlerrm='COMMERCIAL_SECRET_REFERENCE_AUTHORIZATION_IDEMPOTENCY_CONFLICT' then
        v_idempotency_conflict_guard:=true;
      else
        raise;
      end if;
  end;

  v_authorized_decision :=
    public.evaluate_commercial_secret_reference_authorization_request(
      v_authorized_request.id,'MIGRATION_132'
    );

  if v_authorized_decision.decision_status<>'authorized'
     or v_authorized_decision.decision_code<>'AUTHORIZED'
     or not v_authorized_decision.authorized
     or v_authorized_decision.selected_backend_binding_id<>v_binding.id
     or v_authorized_decision.selected_backend_id<>v_backend.id
     or v_authorized_decision.selected_backend_version_id<>v_backend_version.id
     or v_authorized_decision.resolved_scope_type<>'platform'
     or v_authorized_decision.resolved_scope_key<>'platform'
     or v_authorized_decision.resolved_namespace<>v_namespace
     or v_authorized_decision.resolved_capability<>'reference_validation' then
    raise exception 'MIGRATION_132_AUTHORIZED_PATH_FAILED';
  end if;

  -- ===========================================================================
  -- 5. NO_SCOPE_RULE -> HELD
  -- ===========================================================================

  v_held_request :=
    public.enqueue_commercial_secret_reference_authorization_request(
      'migration_132:held:'||v_suffix,
      'migration_132:held_idem:'||v_suffix,
      v_gateway_request.id,
      v_gateway_decision.id,
      'provider',
      'provider_without_rule_'||v_suffix,
      v_namespace,
      'reference_validation',
      'MIGRATION_132',
      v_corr,
      v_cause,
      jsonb_build_object('scenario','NO_SCOPE_RULE')
    );

  v_held_decision :=
    public.evaluate_commercial_secret_reference_authorization_request(
      v_held_request.id,'MIGRATION_132'
    );

  if v_held_decision.decision_status<>'held'
     or v_held_decision.decision_code<>'NO_SCOPE_RULE'
     or v_held_decision.authorized then
    raise exception 'MIGRATION_132_HELD_PATH_FAILED';
  end if;

  -- ===========================================================================
  -- 6. INVALID_SCOPE -> BLOCKED
  -- ===========================================================================

  insert into public.commercial_secret_reference_scope_rules(
    authorization_policy_id,rule_code,rule_status,rule_priority,
    scope_type,scope_key,namespace_pattern,capability_code,
    minimum_backend_trust_tier,allow_reference_routing,
    require_validated_binding,require_active_contract,
    require_namespace_ownership,created_by,approved_by,approved_at,rule_metadata
  ) values (
    v_authorization_policy.id,
    'migration_132:deny_provider:'||v_suffix,
    'approved',
    10,
    'provider',
    'blocked_provider_'||v_suffix,
    v_namespace,
    'reference_validation',
    'validated',
    false,
    true,true,true,
    'MIGRATION_132','MIGRATION_132',clock_timestamp(),
    jsonb_build_object('temporary',true,'scenario','INVALID_SCOPE')
  ) returning * into v_invalid_rule;

  v_invalid_request :=
    public.enqueue_commercial_secret_reference_authorization_request(
      'migration_132:invalid:'||v_suffix,
      'migration_132:invalid_idem:'||v_suffix,
      v_gateway_request.id,
      v_gateway_decision.id,
      'provider',
      'blocked_provider_'||v_suffix,
      v_namespace,
      'reference_validation',
      'MIGRATION_132',
      v_corr,
      v_cause,
      jsonb_build_object('scenario','INVALID_SCOPE')
    );

  v_invalid_decision :=
    public.evaluate_commercial_secret_reference_authorization_request(
      v_invalid_request.id,'MIGRATION_132'
    );

  if v_invalid_decision.decision_status<>'blocked'
     or v_invalid_decision.decision_code<>'INVALID_SCOPE'
     or v_invalid_decision.authorized
     or v_invalid_decision.scope_rule_id<>v_invalid_rule.id then
    raise exception 'MIGRATION_132_INVALID_SCOPE_PATH_FAILED';
  end if;

  -- ===========================================================================
  -- 7. NAMESPACE_NOT_OWNED -> BLOCKED
  -- ===========================================================================

  insert into public.commercial_secret_reference_scope_rules(
    authorization_policy_id,rule_code,rule_status,rule_priority,
    scope_type,scope_key,namespace_pattern,capability_code,
    minimum_backend_trust_tier,allow_reference_routing,
    require_validated_binding,require_active_contract,
    require_namespace_ownership,created_by,approved_by,approved_at,rule_metadata
  ) values (
    v_authorization_policy.id,
    'migration_132:namespace_guard:'||v_suffix,
    'approved',
    10,
    'credential_binding',
    'binding_'||v_suffix,
    v_wrong_namespace,
    'reference_validation',
    'validated',
    true,
    true,true,true,
    'MIGRATION_132','MIGRATION_132',clock_timestamp(),
    jsonb_build_object('temporary',true,'scenario','NAMESPACE_NOT_OWNED')
  ) returning * into v_namespace_rule;

  v_namespace_request :=
    public.enqueue_commercial_secret_reference_authorization_request(
      'migration_132:namespace:'||v_suffix,
      'migration_132:namespace_idem:'||v_suffix,
      v_gateway_request.id,
      v_gateway_decision.id,
      'credential_binding',
      'binding_'||v_suffix,
      v_wrong_namespace,
      'reference_validation',
      'MIGRATION_132',
      v_corr,
      v_cause,
      jsonb_build_object('scenario','NAMESPACE_NOT_OWNED')
    );

  v_namespace_decision :=
    public.evaluate_commercial_secret_reference_authorization_request(
      v_namespace_request.id,'MIGRATION_132'
    );

  if v_namespace_decision.decision_status<>'blocked'
     or v_namespace_decision.decision_code<>'NAMESPACE_NOT_OWNED'
     or v_namespace_decision.authorized
     or v_namespace_decision.scope_rule_id<>v_namespace_rule.id then
    raise exception 'MIGRATION_132_NAMESPACE_PATH_FAILED';
  end if;

  -- ===========================================================================
  -- 8. READ MODEL ASSERTIONS
  -- ===========================================================================

  select * into strict v_read
  from public.commercial_secret_reference_authorization_read_model
  where authorization_request_id=v_authorized_request.id;

  if v_read.request_status<>'authorized'
     or v_read.decision_status<>'authorized'
     or v_read.decision_code<>'AUTHORIZED'
     or not v_read.authorized
     or v_read.evaluation_count<>2
     or v_read.receipt_count<>4
     or v_read.event_count<>2
     or v_read.backend_contact_allowed
     or v_read.authentication_allowed
     or v_read.secret_lookup_allowed
     or v_read.secret_resolution_allowed
     or v_read.decryption_allowed
     or v_read.material_loading_allowed
     or v_read.delivery_allowed
     or v_read.network_access_allowed then
    raise exception
      'MIGRATION_132_AUTHORIZED_READ_MODEL_FAILED evaluations=%, receipts=%, events=%',
      v_read.evaluation_count,v_read.receipt_count,v_read.event_count;
  end if;

  select * into strict v_read
  from public.commercial_secret_reference_authorization_read_model
  where authorization_request_id=v_held_request.id;

  if v_read.request_status<>'held'
     or v_read.decision_status<>'held'
     or v_read.decision_code<>'NO_SCOPE_RULE'
     or v_read.authorized
     or v_read.evaluation_count<>2
     or v_read.receipt_count<>3
     or v_read.event_count<>2 then
    raise exception 'MIGRATION_132_HELD_READ_MODEL_FAILED';
  end if;

  select * into strict v_read
  from public.commercial_secret_reference_authorization_read_model
  where authorization_request_id=v_invalid_request.id;

  if v_read.request_status<>'blocked'
     or v_read.decision_status<>'blocked'
     or v_read.decision_code<>'INVALID_SCOPE'
     or v_read.authorized
     or v_read.evaluation_count<>2
     or v_read.receipt_count<>3
     or v_read.event_count<>2 then
    raise exception 'MIGRATION_132_INVALID_READ_MODEL_FAILED';
  end if;

  select * into strict v_read
  from public.commercial_secret_reference_authorization_read_model
  where authorization_request_id=v_namespace_request.id;

  if v_read.request_status<>'blocked'
     or v_read.decision_status<>'blocked'
     or v_read.decision_code<>'NAMESPACE_NOT_OWNED'
     or v_read.authorized
     or v_read.evaluation_count<>2
     or v_read.receipt_count<>3
     or v_read.event_count<>2 then
    raise exception 'MIGRATION_132_NAMESPACE_READ_MODEL_FAILED';
  end if;

  -- ===========================================================================
  -- 9. EXACT COUNTS
  -- ===========================================================================

  select count(*) into v_backend_count
  from public.commercial_secret_backends where id=v_backend.id;

  select count(*) into v_version_count
  from public.commercial_secret_backend_versions
  where secret_backend_id=v_backend.id;

  select count(*) into v_capability_count
  from public.commercial_secret_backend_capabilities
  where secret_backend_version_id=v_backend_version.id;

  select count(*) into v_binding_count
  from public.commercial_secret_backend_bindings
  where secret_backend_id=v_backend.id;

  select count(*) into v_gateway_request_count
  from public.commercial_secret_reference_gateway_requests
  where id=v_gateway_request.id;

  select count(*) into v_gateway_decision_count
  from public.commercial_secret_reference_gateway_decisions
  where id=v_gateway_decision.id;

  select count(*) into v_auth_request_count
  from public.commercial_secret_reference_authorization_requests
  where id in (
    v_authorized_request.id,v_held_request.id,
    v_invalid_request.id,v_namespace_request.id
  );

  select count(*) into v_auth_evaluation_count
  from public.commercial_secret_reference_authorization_evaluations
  where authorization_request_id in (
    v_authorized_request.id,v_held_request.id,
    v_invalid_request.id,v_namespace_request.id
  );

  select count(*) into v_auth_decision_count
  from public.commercial_secret_reference_authorization_decisions
  where authorization_request_id in (
    v_authorized_request.id,v_held_request.id,
    v_invalid_request.id,v_namespace_request.id
  );

  select count(*) into v_auth_receipt_count
  from public.commercial_secret_reference_authorization_receipts
  where authorization_request_id in (
    v_authorized_request.id,v_held_request.id,
    v_invalid_request.id,v_namespace_request.id
  );

  select count(*) into v_auth_event_count
  from public.commercial_secret_reference_authorization_events
  where authorization_request_id in (
    v_authorized_request.id,v_held_request.id,
    v_invalid_request.id,v_namespace_request.id
  );

  if v_backend_count<>1
     or v_version_count<>1
     or v_capability_count<>5
     or v_binding_count<>1
     or v_gateway_request_count<>1
     or v_gateway_decision_count<>1
     or v_auth_request_count<>4
     or v_auth_evaluation_count<>8
     or v_auth_decision_count<>4
     or v_auth_receipt_count<>13
     or v_auth_event_count<>8 then
    raise exception
      'MIGRATION_132_COUNT_ASSERTION_FAILED backend=%, version=%, capabilities=%, binding=%, gateway_request=%, gateway_decision=%, auth_requests=%, evaluations=%, decisions=%, receipts=%, events=%',
      v_backend_count,v_version_count,v_capability_count,v_binding_count,
      v_gateway_request_count,v_gateway_decision_count,v_auth_request_count,
      v_auth_evaluation_count,v_auth_decision_count,
      v_auth_receipt_count,v_auth_event_count;
  end if;

  -- ===========================================================================
  -- 10. IMMUTABILITY AND APPEND-ONLY GUARDS
  -- ===========================================================================

  begin
    update public.commercial_secret_reference_authorization_policies
    set policy_version=policy_version+1
    where id=v_authorization_policy.id;
    raise exception 'MIGRATION_132_POLICY_GUARD_NOT_ENFORCED';
  exception when others then
    if sqlerrm='COMMERCIAL_SECRET_REFERENCE_AUTHORIZATION_IMMUTABLE' then
      v_policy_guard:=true;
    else raise;
    end if;
  end;

  begin
    update public.commercial_secret_reference_scope_rules
    set rule_priority=rule_priority+1
    where id=v_invalid_rule.id;
    raise exception 'MIGRATION_132_RULE_GUARD_NOT_ENFORCED';
  exception when others then
    if sqlerrm='COMMERCIAL_SECRET_REFERENCE_AUTHORIZATION_IMMUTABLE' then
      v_rule_guard:=true;
    else raise;
    end if;
  end;

  begin
    update public.commercial_secret_reference_authorization_evaluations
    set evaluation_reason='MUTATED'
    where authorization_request_id=v_authorized_request.id;
    raise exception 'MIGRATION_132_EVALUATION_GUARD_NOT_ENFORCED';
  exception when others then
    if sqlerrm='COMMERCIAL_SECRET_REFERENCE_AUTHORIZATION_IMMUTABLE' then
      v_evaluation_guard:=true;
    else raise;
    end if;
  end;

  begin
    update public.commercial_secret_reference_authorization_decisions
    set decision_reason='MUTATED'
    where id=v_authorized_decision.id;
    raise exception 'MIGRATION_132_DECISION_GUARD_NOT_ENFORCED';
  exception when others then
    if sqlerrm='COMMERCIAL_SECRET_REFERENCE_AUTHORIZATION_IMMUTABLE' then
      v_decision_guard:=true;
    else raise;
    end if;
  end;

  begin
    update public.commercial_secret_reference_authorization_receipts
    set receipt_message='MUTATED'
    where authorization_request_id=v_authorized_request.id;
    raise exception 'MIGRATION_132_RECEIPT_GUARD_NOT_ENFORCED';
  exception when others then
    if sqlerrm='COMMERCIAL_SECRET_REFERENCE_AUTHORIZATION_APPEND_ONLY' then
      v_receipt_guard:=true;
    else raise;
    end if;
  end;

  begin
    delete from public.commercial_secret_reference_authorization_events
    where authorization_request_id=v_authorized_request.id;
    raise exception 'MIGRATION_132_EVENT_GUARD_NOT_ENFORCED';
  exception when others then
    if sqlerrm='COMMERCIAL_SECRET_REFERENCE_AUTHORIZATION_APPEND_ONLY' then
      v_event_guard:=true;
    else raise;
    end if;
  end;

  -- ===========================================================================
  -- 11. SENSITIVE-DATA AND ACTIVE-POSTURE GUARDS
  -- ===========================================================================

  begin
    insert into public.commercial_secret_reference_authorization_requests(
      request_key,idempotency_key,authorization_policy_id,
      gateway_request_id,gateway_decision_id,requested_environment,
      requested_scope_type,requested_scope_key,requested_namespace,
      requested_capability,request_status,correlation_id,requested_by,
      request_hash,request_metadata
    ) values (
      'migration_132:plaintext:'||v_suffix,
      'migration_132:plaintext_idem:'||v_suffix,
      v_authorization_policy.id,v_gateway_request.id,v_gateway_decision.id,
      'production','platform','platform',v_namespace,'reference_validation',
      'received',v_corr,'MIGRATION_132',repeat('a',64),
      '{"api_key":"FORBIDDEN"}'::jsonb
    );
    raise exception 'MIGRATION_132_PLAINTEXT_GUARD_NOT_ENFORCED';
  exception when check_violation then
    v_plaintext_guard:=true;
  end;

  begin
    insert into public.commercial_secret_reference_authorization_requests(
      request_key,idempotency_key,authorization_policy_id,
      gateway_request_id,gateway_decision_id,requested_environment,
      requested_scope_type,requested_scope_key,requested_namespace,
      requested_capability,request_status,correlation_id,requested_by,
      request_hash,request_metadata
    ) values (
      'migration_132:endpoint:'||v_suffix,
      'migration_132:endpoint_idem:'||v_suffix,
      v_authorization_policy.id,v_gateway_request.id,v_gateway_decision.id,
      'production','platform','platform',v_namespace,'reference_validation',
      'received',v_corr,'MIGRATION_132',repeat('b',64),
      '{"endpoint":"forbidden.example"}'::jsonb
    );
    raise exception 'MIGRATION_132_ENDPOINT_GUARD_NOT_ENFORCED';
  exception when check_violation then
    v_endpoint_guard:=true;
  end;

  begin
    insert into public.commercial_secret_reference_authorization_requests(
      request_key,idempotency_key,authorization_policy_id,
      gateway_request_id,gateway_decision_id,requested_environment,
      requested_scope_type,requested_scope_key,requested_namespace,
      requested_capability,request_status,correlation_id,requested_by,
      request_hash,request_metadata
    ) values (
      'migration_132:active_probe:'||v_suffix,
      'migration_132:active_probe_idem:'||v_suffix,
      v_authorization_policy.id,v_gateway_request.id,v_gateway_decision.id,
      'production','platform','platform',v_namespace,'reference_validation',
      'received',v_corr,'MIGRATION_132',repeat('d',64),'{}'::jsonb
    ) returning id into v_held_request.id;

    insert into public.commercial_secret_reference_authorization_decisions(
      authorization_request_id,decision_status,decision_code,authorized,
      selected_backend_binding_id,selected_backend_id,selected_backend_version_id,
      resolved_scope_type,resolved_scope_key,resolved_namespace,resolved_capability,
      backend_contact_allowed,decided_by,decision_hash,decision_metadata
    ) values (
      v_held_request.id,'authorized','AUTHORIZED',true,
      v_binding.id,v_backend.id,v_backend_version.id,
      'platform','platform',v_namespace,'reference_validation',
      true,'MIGRATION_132',repeat('e',64),
      '{"passive_authorization_only":true}'::jsonb
    );

    raise exception 'MIGRATION_132_ACTIVE_DECISION_GUARD_NOT_ENFORCED';
  exception when check_violation then
    v_active_decision_guard:=true;
  end;

  if not (
    v_idempotency_conflict_guard
    and v_policy_guard
    and v_rule_guard
    and v_evaluation_guard
    and v_decision_guard
    and v_receipt_guard
    and v_event_guard
    and v_plaintext_guard
    and v_endpoint_guard
    and v_active_decision_guard
  ) then
    raise exception 'MIGRATION_132_GUARD_MATRIX_FAILED';
  end if;

  -- ===========================================================================
  -- 12. ECONOMIC/RUNTIME NON-MUTATION
  -- ===========================================================================

  select count(*) into v_purchase_after from public.commercial_purchases;
  select count(*) into v_checkout_after from public.commercial_checkout_sessions;
  select count(*) into v_provider_request_after from public.commercial_checkout_provider_requests;
  select count(*) into v_callback_after from public.commercial_checkout_callbacks;
  select count(*) into v_reconciliation_after from public.commercial_checkout_reconciliation_observations;
  select count(*) into v_wallet_after from public.commercial_wallets;
  select count(*) into v_ledger_after from public.commercial_ledger;
  select count(*) into v_outbox_after from public.commercial_purchase_runtime_outbox;

  if v_purchase_after<>v_purchase_before
     or v_checkout_after<>v_checkout_before
     or v_provider_request_after<>v_provider_request_before
     or v_callback_after<>v_callback_before
     or v_reconciliation_after<>v_reconciliation_before
     or v_wallet_after<>v_wallet_before
     or v_ledger_after<>v_ledger_before
     or v_outbox_after<>v_outbox_before then
    raise exception 'MIGRATION_132_ECONOMIC_NON_MUTATION_FAILED';
  end if;

  -- ===========================================================================
  -- 13. FINAL CERTIFICATION
  -- ===========================================================================

  raise notice
    'MIGRATION_132_CERTIFIED backend_count=%, version_count=%, capability_count=%, binding_count=%, gateway_request_count=%, gateway_decision_count=%, authorization_request_count=%, evaluation_count=%, decision_count=%, receipt_count=%, event_count=%, authorized_count=1, held_count=1, blocked_count=2, authorized_code=AUTHORIZED, held_code=NO_SCOPE_RULE, invalid_scope_code=INVALID_SCOPE, namespace_code=NAMESPACE_NOT_OWNED, idempotency_conflict_guard=%, policy_guard=%, rule_guard=%, evaluation_guard=%, decision_guard=%, receipt_guard=%, event_guard=%, plaintext_guard=%, endpoint_guard=%, active_decision_guard=%, automatic_dispatch_enabled=false, endpoint_discovery_enabled=false, backend_probe_enabled=false, backend_contact_enabled=false, backend_authentication_enabled=false, secret_lookup_enabled=false, secret_resolution_enabled=false, secret_decryption_enabled=false, credential_material_loading_enabled=false, credential_delivery_enabled=false, network_access_enabled=false, opaque_references_only=true, purchase_delta=0, checkout_delta=0, provider_request_delta=0, callback_delta=0, reconciliation_delta=0, wallet_delta=0, ledger_delta=0, outbox_delta=0, rollback_required=true',
    v_backend_count,v_version_count,v_capability_count,v_binding_count,
    v_gateway_request_count,v_gateway_decision_count,v_auth_request_count,
    v_auth_evaluation_count,v_auth_decision_count,v_auth_receipt_count,
    v_auth_event_count,v_idempotency_conflict_guard,v_policy_guard,
    v_rule_guard,v_evaluation_guard,v_decision_guard,v_receipt_guard,
    v_event_guard,v_plaintext_guard,v_endpoint_guard,v_active_decision_guard;
end
$$;

rollback;

\echo ''
\echo 'MIGRATION_132_TRANSACTION_ROLLED_BACK'
\echo 'No temporary backend, capability, binding, gateway object, authorization rule, request, evaluation, decision, receipt, event, policy change, purchase, checkout, wallet, ledger or outbox mutation was persisted.'
