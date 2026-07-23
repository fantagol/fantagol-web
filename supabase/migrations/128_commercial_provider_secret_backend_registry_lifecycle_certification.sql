-- =============================================================================
-- FANTAGOL
-- Migration: 128_commercial_provider_secret_backend_registry_lifecycle_certification.sql
-- Milestone: Commercial Platform - Provider Secret Backend Registry
--
-- Purpose:
--   Transactionally certify the complete passive lifecycle introduced by
--   migration 127:
--
--     backend registration
--     immutable contract version registration
--     passive capability declaration
--     offline version validation
--     passive orchestrator binding
--     binding validation
--     blocked backend probe recording
--     receipt and event append-only guarantees
--     registry read-model integrity
--     safety constraints and economic non-mutation
--
--   The complete certification ends with ROLLBACK. No temporary object or
--   policy mutation is persisted.
-- =============================================================================

\set ON_ERROR_STOP on
\timing on

begin;

set local statement_timeout = '120s';
set local lock_timeout = '15s';
set local idle_in_transaction_session_timeout = '180s';

do $$
declare
  -- ---------------------------------------------------------------------------
  -- Registry lifecycle objects
  -- ---------------------------------------------------------------------------
  v_registry_policy public.commercial_secret_backend_registry_policies;
  v_orchestrator_policy public.commercial_secret_resolution_policies;

  v_backend public.commercial_secret_backends;
  v_backend_version public.commercial_secret_backend_versions;
  v_capability_reference public.commercial_secret_backend_capabilities;
  v_capability_versions public.commercial_secret_backend_capabilities;
  v_capability_rotation public.commercial_secret_backend_capabilities;
  v_capability_expiry public.commercial_secret_backend_capabilities;
  v_capability_scope public.commercial_secret_backend_capabilities;
  v_binding public.commercial_secret_backend_bindings;
  v_probe public.commercial_secret_backend_probe_attempts;
  v_read_model public.commercial_secret_backend_registry_read_model;

  -- ---------------------------------------------------------------------------
  -- Generated test identities
  -- ---------------------------------------------------------------------------
  v_suffix text :=
    upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));

  v_backend_code text;
  v_backend_name text;
  v_reference_namespace text;
  v_binding_key text;

  v_reference_fingerprint text :=
    encode(extensions.digest(gen_random_uuid()::text, 'sha256'), 'hex');

  v_contract_hash text :=
    encode(extensions.digest(gen_random_uuid()::text, 'sha256'), 'hex');

  v_reference_schema_hash text :=
    encode(extensions.digest(gen_random_uuid()::text, 'sha256'), 'hex');

  v_correlation_id uuid := gen_random_uuid();

  -- ---------------------------------------------------------------------------
  -- Lifecycle counts
  -- ---------------------------------------------------------------------------
  v_backend_count bigint;
  v_version_count bigint;
  v_capability_count bigint;
  v_validated_capability_count bigint;
  v_binding_count bigint;
  v_validated_binding_count bigint;
  v_receipt_count bigint;
  v_probe_count bigint;
  v_event_count bigint;

  -- ---------------------------------------------------------------------------
  -- Safety and immutability guards
  -- ---------------------------------------------------------------------------
  v_policy_guard boolean := false;
  v_backend_version_guard boolean := false;
  v_capability_guard boolean := false;
  v_receipt_guard boolean := false;
  v_event_guard boolean := false;

  v_plaintext_guard boolean := false;
  v_endpoint_guard boolean := false;
  v_unsafe_version_guard boolean := false;
  v_unsafe_capability_guard boolean := false;
  v_unsafe_binding_guard boolean := false;
  v_unsafe_probe_guard boolean := false;

  -- ---------------------------------------------------------------------------
  -- Baseline economic/runtime counts
  -- ---------------------------------------------------------------------------
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
  -- 1. DEPENDENCY ASSERTIONS
  -- ===========================================================================

  if to_regclass('public.commercial_secret_backend_registry_policies') is null
     or to_regclass('public.commercial_secret_backends') is null
     or to_regclass('public.commercial_secret_backend_versions') is null
     or to_regclass('public.commercial_secret_backend_capabilities') is null
     or to_regclass('public.commercial_secret_backend_bindings') is null
     or to_regclass('public.commercial_secret_backend_validation_receipts') is null
     or to_regclass('public.commercial_secret_backend_probe_attempts') is null
     or to_regclass('public.commercial_secret_backend_events') is null
     or to_regclass('public.commercial_secret_backend_registry_read_model') is null then
    raise exception 'MIGRATION_128_REQUIRES_MIGRATION_127_TABLES';
  end if;

  if to_regprocedure(
       'public.register_commercial_secret_backend(text,text,text,text,text,text,text,text,text,text,text,uuid,jsonb)'
     ) is null
     or to_regprocedure(
       'public.register_commercial_secret_backend_version(uuid,integer,text,text,text,text,boolean,boolean,boolean,boolean,text,uuid,jsonb)'
     ) is null
     or to_regprocedure(
       'public.register_commercial_secret_backend_capability(uuid,text,text,text,uuid,jsonb)'
     ) is null
     or to_regprocedure(
       'public.validate_commercial_secret_backend_version(uuid,text,uuid)'
     ) is null
     or to_regprocedure(
       'public.register_commercial_secret_backend_binding(text,uuid,uuid,uuid,uuid,text,integer,text,text,uuid,jsonb)'
     ) is null
     or to_regprocedure(
       'public.validate_commercial_secret_backend_binding(uuid,text,uuid)'
     ) is null
     or to_regprocedure(
       'public.record_blocked_secret_backend_probe(uuid,uuid,uuid,text,text,uuid)'
     ) is null then
    raise exception 'MIGRATION_128_REQUIRES_MIGRATION_127_FUNCTIONS';
  end if;

  select *
  into strict v_registry_policy
  from public.commercial_secret_backend_registry_policies
  where policy_code = 'commercial:provider_secret_backend_registry:v1'
    and environment = 'production'
    and policy_status = 'approved';

  select *
  into strict v_orchestrator_policy
  from public.commercial_secret_resolution_policies
  where policy_code = 'commercial:provider_secret_resolution:v1'
    and environment = 'production'
    and policy_status = 'approved';

  if v_registry_policy.endpoint_discovery_enabled
     or v_registry_policy.backend_probe_enabled
     or v_registry_policy.backend_contact_enabled
     or v_registry_policy.backend_authentication_enabled
     or v_registry_policy.secret_lookup_enabled
     or v_registry_policy.secret_resolution_enabled
     or v_registry_policy.secret_decryption_enabled
     or v_registry_policy.credential_material_loading_enabled
     or v_registry_policy.credential_delivery_enabled
     or v_registry_policy.network_access_enabled then
    raise exception 'MIGRATION_128_UNSAFE_REGISTRY_POLICY';
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
  -- 3. TEMPORARY BACKEND REGISTRATION
  -- ===========================================================================

  v_backend_code := lower('migration_128_backend_' || v_suffix);
  v_backend_name := 'Migration 128 Passive Backend ' || v_suffix;
  v_reference_namespace := lower('migration_128:opaque:' || v_suffix);
  v_binding_key := lower('migration_128:binding:' || v_suffix);

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
    'MIGRATION_128',
    v_correlation_id,
    jsonb_build_object(
      'temporary', true,
      'certification', 'MIGRATION_128',
      'opaque_references_only', true
    )
  );

  if v_backend.backend_status <> 'draft'
     or v_backend.trust_tier <> 'registered'
     or v_backend.reference_fingerprint <> v_reference_fingerprint
     or v_backend.active_version_id is not null then
    raise exception
      'MIGRATION_128_BACKEND_REGISTRATION_FAILED status=%, trust=%, active_version=%',
      v_backend.backend_status,
      v_backend.trust_tier,
      v_backend.active_version_id;
  end if;

  raise notice
    'MIGRATION_128_TEMPORARY_BACKEND_CREATED backend_id=%, backend_code=%, reference_namespace=%',
    v_backend.id,
    v_backend.backend_code,
    v_backend.reference_namespace;

  -- ===========================================================================
  -- 4. CONTRACT VERSION REGISTRATION
  -- ===========================================================================

  v_backend_version := public.register_commercial_secret_backend_version(
    v_backend.id,
    1,
    'FantaGol Passive Secret Backend Contract',
    '1.0.0',
    v_contract_hash,
    v_reference_schema_hash,
    true,
    true,
    true,
    true,
    'MIGRATION_128',
    v_correlation_id,
    jsonb_build_object(
      'temporary', true,
      'certification', 'MIGRATION_128',
      'passive_only', true
    )
  );

  if v_backend_version.version_status <> 'draft'
     or v_backend_version.supports_reference_validation is not true
     or v_backend_version.supports_versioned_references is not true
     or v_backend_version.supports_rotation_metadata is not true
     or v_backend_version.supports_expiry_metadata is not true
     or v_backend_version.supports_scope_metadata is not true
     or v_backend_version.supports_endpoint_discovery
     or v_backend_version.supports_backend_probe
     or v_backend_version.supports_backend_contact
     or v_backend_version.supports_authentication
     or v_backend_version.supports_secret_lookup
     or v_backend_version.supports_secret_resolution
     or v_backend_version.supports_decryption
     or v_backend_version.supports_material_loading
     or v_backend_version.supports_delivery
     or v_backend_version.supports_network_access then
    raise exception 'MIGRATION_128_BACKEND_VERSION_REGISTRATION_FAILED';
  end if;

  -- ===========================================================================
  -- 5. PASSIVE CAPABILITY DECLARATION
  -- ===========================================================================

  v_capability_reference :=
    public.register_commercial_secret_backend_capability(
      v_backend_version.id,
      'reference_validation',
      'reference_validation',
      'MIGRATION_128',
      v_correlation_id,
      jsonb_build_object('temporary',true,'offline_only',true)
    );

  v_capability_versions :=
    public.register_commercial_secret_backend_capability(
      v_backend_version.id,
      'versioned_references',
      'version_metadata',
      'MIGRATION_128',
      v_correlation_id,
      jsonb_build_object('temporary',true,'offline_only',true)
    );

  v_capability_rotation :=
    public.register_commercial_secret_backend_capability(
      v_backend_version.id,
      'rotation_metadata',
      'rotation_metadata',
      'MIGRATION_128',
      v_correlation_id,
      jsonb_build_object('temporary',true,'offline_only',true)
    );

  v_capability_expiry :=
    public.register_commercial_secret_backend_capability(
      v_backend_version.id,
      'expiry_metadata',
      'expiry_metadata',
      'MIGRATION_128',
      v_correlation_id,
      jsonb_build_object('temporary',true,'offline_only',true)
    );

  v_capability_scope :=
    public.register_commercial_secret_backend_capability(
      v_backend_version.id,
      'scope_metadata',
      'scope_metadata',
      'MIGRATION_128',
      v_correlation_id,
      jsonb_build_object('temporary',true,'offline_only',true)
    );

  if v_capability_reference.capability_status <> 'declared'
     or v_capability_versions.capability_status <> 'declared'
     or v_capability_rotation.capability_status <> 'declared'
     or v_capability_expiry.capability_status <> 'declared'
     or v_capability_scope.capability_status <> 'declared' then
    raise exception 'MIGRATION_128_CAPABILITY_DECLARATION_FAILED';
  end if;

  if exists (
    select 1
    from public.commercial_secret_backend_capabilities
    where secret_backend_version_id = v_backend_version.id
      and (
        passive_only is not true
        or requires_backend_contact
        or requires_authentication
        or requires_secret_material
        or requires_network
      )
  ) then
    raise exception 'MIGRATION_128_UNSAFE_CAPABILITY_DECLARED';
  end if;

  -- ===========================================================================
  -- 6. OFFLINE VERSION VALIDATION
  -- ===========================================================================

  v_backend_version :=
    public.validate_commercial_secret_backend_version(
      v_backend_version.id,
      'MIGRATION_128',
      v_correlation_id
    );

  if v_backend_version.version_status <> 'validated'
     or v_backend_version.validated_by <> 'MIGRATION_128'
     or v_backend_version.validated_at is null then
    raise exception
      'MIGRATION_128_VERSION_VALIDATION_FAILED status=%',
      v_backend_version.version_status;
  end if;

  select *
  into strict v_backend
  from public.commercial_secret_backends
  where id = v_backend.id;

  if v_backend.backend_status <> 'validated'
     or v_backend.trust_tier <> 'validated'
     or v_backend.active_version_id <> v_backend_version.id then
    raise exception
      'MIGRATION_128_BACKEND_ACTIVATION_FAILED status=%, trust=%, active_version=%',
      v_backend.backend_status,
      v_backend.trust_tier,
      v_backend.active_version_id;
  end if;

  if exists (
    select 1
    from public.commercial_secret_backend_capabilities
    where secret_backend_version_id = v_backend_version.id
      and (
        capability_status <> 'validated'
        or validated_by <> 'MIGRATION_128'
        or validated_at is null
      )
  ) then
    raise exception 'MIGRATION_128_CAPABILITY_VALIDATION_FAILED';
  end if;

  -- ===========================================================================
  -- 7. PASSIVE ORCHESTRATOR BINDING
  -- ===========================================================================

  v_binding := public.register_commercial_secret_backend_binding(
    v_binding_key,
    v_backend.id,
    v_backend_version.id,
    null,
    v_orchestrator_policy.id,
    'platform',
    100,
    v_reference_namespace,
    'MIGRATION_128',
    v_correlation_id,
    jsonb_build_object(
      'temporary', true,
      'certification', 'MIGRATION_128',
      'passive_only', true
    )
  );

  if v_binding.binding_status <> 'draft'
     or v_binding.backend_contact_allowed
     or v_binding.authentication_allowed
     or v_binding.secret_lookup_allowed
     or v_binding.secret_resolution_allowed
     or v_binding.decryption_allowed
     or v_binding.material_loading_allowed
     or v_binding.delivery_allowed
     or v_binding.network_access_allowed then
    raise exception 'MIGRATION_128_BINDING_REGISTRATION_FAILED';
  end if;

  v_binding := public.validate_commercial_secret_backend_binding(
    v_binding.id,
    'MIGRATION_128',
    v_correlation_id
  );

  if v_binding.binding_status <> 'validated'
     or v_binding.validated_by <> 'MIGRATION_128'
     or v_binding.validated_at is null then
    raise exception
      'MIGRATION_128_BINDING_VALIDATION_FAILED status=%',
      v_binding.binding_status;
  end if;

  -- ===========================================================================
  -- 8. BLOCKED BACKEND PROBE
  -- ===========================================================================

  v_probe := public.record_blocked_secret_backend_probe(
    v_backend.id,
    v_backend_version.id,
    v_binding.id,
    'MIGRATION_128',
    'PASSIVE_REGISTRY_BACKEND_PROBE_DISABLED',
    v_correlation_id
  );

  if v_probe.attempt_status <> 'blocked'
     or v_probe.endpoint_discovery_requested
     or v_probe.endpoint_discovery_performed
     or v_probe.backend_probe_requested
     or v_probe.backend_probe_performed
     or v_probe.backend_contact_requested
     or v_probe.backend_contact_performed
     or v_probe.authentication_requested
     or v_probe.authentication_performed
     or v_probe.secret_lookup_requested
     or v_probe.secret_lookup_performed
     or v_probe.secret_material_observed
     or v_probe.network_attempted then
    raise exception 'MIGRATION_128_BLOCKED_PROBE_ASSERTION_FAILED';
  end if;

  -- ===========================================================================
  -- 9. READ MODEL AND EXACT COUNTS
  -- ===========================================================================

  select *
  into strict v_read_model
  from public.commercial_secret_backend_registry_read_model
  where secret_backend_id = v_backend.id;

  if v_read_model.backend_status <> 'validated'
     or v_read_model.trust_tier <> 'validated'
     or v_read_model.active_version_status <> 'validated'
     or v_read_model.capability_count <> 5
     or v_read_model.validated_capability_count <> 5
     or v_read_model.binding_count <> 1
     or v_read_model.validated_binding_count <> 1
     or v_read_model.receipt_count <> 6
     or v_read_model.probe_attempt_count <> 1
     or v_read_model.event_count <> 11
     or v_read_model.endpoint_discovery_enabled
     or v_read_model.backend_probe_enabled
     or v_read_model.backend_contact_enabled
     or v_read_model.backend_authentication_enabled
     or v_read_model.secret_lookup_enabled
     or v_read_model.secret_resolution_enabled
     or v_read_model.secret_decryption_enabled
     or v_read_model.credential_material_loading_enabled
     or v_read_model.credential_delivery_enabled
     or v_read_model.network_access_enabled then
    raise exception
      'MIGRATION_128_READ_MODEL_FAILED status=%, trust=%, capabilities=%/%, bindings=%/%, receipts=%, probes=%, events=%',
      v_read_model.backend_status,
      v_read_model.trust_tier,
      v_read_model.capability_count,
      v_read_model.validated_capability_count,
      v_read_model.binding_count,
      v_read_model.validated_binding_count,
      v_read_model.receipt_count,
      v_read_model.probe_attempt_count,
      v_read_model.event_count;
  end if;

  select count(*) into v_backend_count
  from public.commercial_secret_backends
  where id = v_backend.id;

  select count(*) into v_version_count
  from public.commercial_secret_backend_versions
  where secret_backend_id = v_backend.id;

  select count(*) into v_capability_count
  from public.commercial_secret_backend_capabilities
  where secret_backend_version_id = v_backend_version.id;

  select count(*) into v_validated_capability_count
  from public.commercial_secret_backend_capabilities
  where secret_backend_version_id = v_backend_version.id
    and capability_status = 'validated';

  select count(*) into v_binding_count
  from public.commercial_secret_backend_bindings
  where secret_backend_id = v_backend.id;

  select count(*) into v_validated_binding_count
  from public.commercial_secret_backend_bindings
  where secret_backend_id = v_backend.id
    and binding_status = 'validated';

  select count(*) into v_receipt_count
  from public.commercial_secret_backend_validation_receipts
  where secret_backend_id = v_backend.id;

  select count(*) into v_probe_count
  from public.commercial_secret_backend_probe_attempts
  where secret_backend_id = v_backend.id;

  select count(*) into v_event_count
  from public.commercial_secret_backend_events
  where secret_backend_id = v_backend.id;

  if v_backend_count <> 1
     or v_version_count <> 1
     or v_capability_count <> 5
     or v_validated_capability_count <> 5
     or v_binding_count <> 1
     or v_validated_binding_count <> 1
     or v_receipt_count <> 6
     or v_probe_count <> 1
     or v_event_count <> 11 then
    raise exception
      'MIGRATION_128_COUNT_ASSERTION_FAILED backend=%, version=%, capability=%, validated_capability=%, binding=%, validated_binding=%, receipt=%, probe=%, event=%',
      v_backend_count,
      v_version_count,
      v_capability_count,
      v_validated_capability_count,
      v_binding_count,
      v_validated_binding_count,
      v_receipt_count,
      v_probe_count,
      v_event_count;
  end if;

  -- ===========================================================================
  -- 10. IMMUTABILITY AND APPEND-ONLY GUARDS
  -- ===========================================================================

  begin
    update public.commercial_secret_backend_registry_policies
    set maximum_versions_per_backend = maximum_versions_per_backend + 1
    where id = v_registry_policy.id;

    raise exception 'MIGRATION_128_POLICY_GUARD_NOT_ENFORCED';
  exception
    when others then
      if sqlerrm = 'COMMERCIAL_SECRET_BACKEND_REGISTRY_POLICY_IMMUTABLE' then
        v_policy_guard := true;
      else
        raise;
      end if;
  end;

  begin
    update public.commercial_secret_backend_versions
    set contract_version = 'MUTATED'
    where id = v_backend_version.id;

    raise exception 'MIGRATION_128_VERSION_GUARD_NOT_ENFORCED';
  exception
    when others then
      if sqlerrm = 'COMMERCIAL_SECRET_BACKEND_VERSION_IMMUTABLE' then
        v_backend_version_guard := true;
      else
        raise;
      end if;
  end;

  begin
    update public.commercial_secret_backend_capabilities
    set capability_code = 'mutated_capability'
    where id = v_capability_reference.id;

    raise exception 'MIGRATION_128_CAPABILITY_GUARD_NOT_ENFORCED';
  exception
    when others then
      if sqlerrm = 'COMMERCIAL_SECRET_BACKEND_CAPABILITY_IMMUTABLE' then
        v_capability_guard := true;
      else
        raise;
      end if;
  end;

  begin
    update public.commercial_secret_backend_validation_receipts
    set validation_status = 'accepted'
    where secret_backend_id = v_backend.id;

    raise exception 'MIGRATION_128_RECEIPT_GUARD_NOT_ENFORCED';
  exception
    when others then
      if sqlerrm = 'COMMERCIAL_SECRET_BACKEND_RECEIPT_APPEND_ONLY' then
        v_receipt_guard := true;
      else
        raise;
      end if;
  end;

  begin
    delete from public.commercial_secret_backend_events
    where secret_backend_id = v_backend.id;

    raise exception 'MIGRATION_128_EVENT_GUARD_NOT_ENFORCED';
  exception
    when others then
      if sqlerrm = 'COMMERCIAL_SECRET_BACKEND_EVENT_APPEND_ONLY' then
        v_event_guard := true;
      else
        raise;
      end if;
  end;

  -- ===========================================================================
  -- 11. SENSITIVE METADATA AND EXECUTION SAFETY GUARDS
  -- ===========================================================================

  begin
    insert into public.commercial_secret_backends (
      backend_code,
      backend_name,
      backend_type,
      environment,
      backend_status,
      trust_tier,
      ownership_scope,
      residency_class,
      reference_namespace,
      reference_fingerprint,
      registration_hash,
      registered_by,
      backend_metadata
    ) values (
      lower('migration_128_plaintext_' || v_suffix),
      'Forbidden plaintext backend',
      'development_stub',
      'production',
      'draft',
      'registered',
      'platform',
      'unspecified',
      lower('migration_128:plaintext:' || v_suffix),
      repeat('a',64),
      repeat('b',64),
      'MIGRATION_128',
      jsonb_build_object('api_key','FORBIDDEN')
    );

    raise exception 'MIGRATION_128_PLAINTEXT_GUARD_NOT_ENFORCED';
  exception
    when check_violation then
      v_plaintext_guard := true;
  end;

  begin
    insert into public.commercial_secret_backends (
      backend_code,
      backend_name,
      backend_type,
      environment,
      backend_status,
      trust_tier,
      ownership_scope,
      residency_class,
      reference_namespace,
      reference_fingerprint,
      registration_hash,
      registered_by,
      backend_metadata
    ) values (
      lower('migration_128_endpoint_' || v_suffix),
      'Forbidden endpoint backend',
      'development_stub',
      'production',
      'draft',
      'registered',
      'platform',
      'unspecified',
      lower('migration_128:endpoint:' || v_suffix),
      repeat('c',64),
      repeat('d',64),
      'MIGRATION_128',
      jsonb_build_object('endpoint','forbidden.example')
    );

    raise exception 'MIGRATION_128_ENDPOINT_GUARD_NOT_ENFORCED';
  exception
    when check_violation then
      v_endpoint_guard := true;
  end;

  begin
    insert into public.commercial_secret_backend_versions (
      secret_backend_id,
      version_number,
      version_status,
      contract_name,
      contract_version,
      contract_hash,
      reference_schema_hash,
      supports_reference_validation,
      supports_backend_contact,
      registered_by
    ) values (
      v_backend.id,
      99,
      'draft',
      'Unsafe Contract',
      '99.0.0',
      repeat('e',64),
      repeat('f',64),
      true,
      true,
      'MIGRATION_128'
    );

    raise exception 'MIGRATION_128_UNSAFE_VERSION_GUARD_NOT_ENFORCED';
  exception
    when check_violation then
      v_unsafe_version_guard := true;
  end;

  begin
    insert into public.commercial_secret_backend_capabilities (
      secret_backend_version_id,
      capability_code,
      capability_class,
      capability_status,
      passive_only,
      requires_network,
      declared_by,
      capability_metadata
    ) values (
      v_backend_version.id,
      'unsafe_network_capability',
      'reference_validation',
      'declared',
      true,
      true,
      'MIGRATION_128',
      '{}'::jsonb
    );

    raise exception 'MIGRATION_128_UNSAFE_CAPABILITY_GUARD_NOT_ENFORCED';
  exception
    when check_violation then
      v_unsafe_capability_guard := true;
  end;

  begin
    insert into public.commercial_secret_backend_bindings (
      binding_key,
      secret_backend_id,
      secret_backend_version_id,
      credential_binding_id,
      orchestrator_policy_id,
      binding_status,
      binding_scope,
      priority,
      reference_namespace,
      binding_hash,
      backend_contact_allowed,
      bound_by
    ) values (
      lower('migration_128:unsafe_binding:' || v_suffix),
      v_backend.id,
      v_backend_version.id,
      null,
      v_orchestrator_policy.id,
      'draft',
      'platform',
      999,
      v_reference_namespace,
      repeat('1',64),
      true,
      'MIGRATION_128'
    );

    raise exception 'MIGRATION_128_UNSAFE_BINDING_GUARD_NOT_ENFORCED';
  exception
    when check_violation then
      v_unsafe_binding_guard := true;
  end;

  begin
    insert into public.commercial_secret_backend_probe_attempts (
      secret_backend_id,
      secret_backend_version_id,
      secret_backend_binding_id,
      attempt_number,
      attempt_status,
      backend_probe_requested,
      recorded_by,
      reason
    ) values (
      v_backend.id,
      v_backend_version.id,
      v_binding.id,
      99,
      'blocked',
      true,
      'MIGRATION_128',
      'FORBIDDEN_ACTIVE_PROBE'
    );

    raise exception 'MIGRATION_128_UNSAFE_PROBE_GUARD_NOT_ENFORCED';
  exception
    when check_violation then
      v_unsafe_probe_guard := true;
  end;

  if not (
    v_policy_guard
    and v_backend_version_guard
    and v_capability_guard
    and v_receipt_guard
    and v_event_guard
    and v_plaintext_guard
    and v_endpoint_guard
    and v_unsafe_version_guard
    and v_unsafe_capability_guard
    and v_unsafe_binding_guard
    and v_unsafe_probe_guard
  ) then
    raise exception 'MIGRATION_128_GUARD_MATRIX_FAILED';
  end if;

  -- ===========================================================================
  -- 12. ECONOMIC/RUNTIME NON-MUTATION
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
      'MIGRATION_128_ECONOMIC_NON_MUTATION_FAILED purchase_delta=%, checkout_session_delta=%, provider_request_delta=%, callback_delta=%, reconciliation_delta=%, wallet_delta=%, ledger_delta=%, outbox_delta=%',
      v_purchase_after - v_purchase_before,
      v_checkout_session_after - v_checkout_session_before,
      v_provider_request_after - v_provider_request_before,
      v_callback_after - v_callback_before,
      v_reconciliation_after - v_reconciliation_before,
      v_wallet_after - v_wallet_before,
      v_ledger_after - v_ledger_before,
      v_outbox_after - v_outbox_before;
  end if;

  -- ===========================================================================
  -- 13. FINAL CERTIFICATION NOTICE
  -- ===========================================================================

  raise notice
    'MIGRATION_128_CERTIFIED backend_count=%, version_count=%, capability_count=%, validated_capability_count=%, binding_count=%, validated_binding_count=%, receipt_count=%, probe_attempt_count=%, event_count=%, backend_status=%, trust_tier=%, active_version_status=%, policy_guard=%, backend_version_guard=%, capability_guard=%, receipt_guard=%, event_guard=%, plaintext_guard=%, endpoint_guard=%, unsafe_version_guard=%, unsafe_capability_guard=%, unsafe_binding_guard=%, unsafe_probe_guard=%, endpoint_discovery_enabled=false, backend_probe_enabled=false, backend_contact_enabled=false, backend_authentication_enabled=false, secret_lookup_enabled=false, secret_resolution_enabled=false, secret_decryption_enabled=false, credential_material_loading_enabled=false, credential_delivery_enabled=false, network_access_enabled=false, opaque_references_only=true, purchase_delta=0, checkout_session_delta=0, provider_request_delta=0, callback_delta=0, reconciliation_delta=0, wallet_delta=0, ledger_delta=0, outbox_delta=0, rollback_required=true',
    v_backend_count,
    v_version_count,
    v_capability_count,
    v_validated_capability_count,
    v_binding_count,
    v_validated_binding_count,
    v_receipt_count,
    v_probe_count,
    v_event_count,
    v_read_model.backend_status,
    v_read_model.trust_tier,
    v_read_model.active_version_status,
    v_policy_guard,
    v_backend_version_guard,
    v_capability_guard,
    v_receipt_guard,
    v_event_guard,
    v_plaintext_guard,
    v_endpoint_guard,
    v_unsafe_version_guard,
    v_unsafe_capability_guard,
    v_unsafe_binding_guard,
    v_unsafe_probe_guard;
end
$$;

rollback;

\echo ''
\echo 'MIGRATION_128_TRANSACTION_ROLLED_BACK'
\echo 'No secret backend, version, capability, binding, probe attempt, receipt, event, policy change, checkout record, purchase, wallet, ledger or outbox mutation was persisted.'
