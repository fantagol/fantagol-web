-- =============================================================================
-- FANTAGOL
-- Migration: 126_commercial_provider_secret_resolution_orchestrator_lifecycle_certification.sql
-- Milestone: Commercial Platform - Provider Secret Resolution Orchestrator Lifecycle Certification
--
-- Purpose:
--   Transactionally certify migration 125 together with the credential-vault and
--   provider-adapter foundations established by migrations 117-124. The complete
--   test ends with ROLLBACK and persists no temporary data or policy changes.
-- =============================================================================

\set ON_ERROR_STOP on

begin;

set local statement_timeout = '180s';
set local lock_timeout = '15s';
set local idle_in_transaction_session_timeout = '240s';

do $$
declare
  v_adapter_policy public.commercial_provider_adapter_policies;
  v_provider public.commercial_providers;
  v_contract public.commercial_provider_adapter_contracts;
  v_version public.commercial_provider_adapter_versions;
  v_create_operation public.commercial_provider_adapter_operations;
  v_operation public.commercial_provider_adapter_operations;
  v_error_mapping public.commercial_provider_adapter_error_mappings;
  v_validation public.commercial_provider_adapter_validations;
  v_binding public.commercial_provider_adapter_bindings;

  v_credential_policy public.commercial_provider_credential_policies;
  v_profile public.commercial_provider_credential_profiles;
  v_credential_version public.commercial_provider_credential_versions;
  v_credential_binding public.commercial_provider_credential_bindings;
  v_request public.commercial_provider_credential_access_requests;
  v_replay public.commercial_provider_credential_access_requests;
  v_attempt public.commercial_provider_credential_resolution_attempts;
  v_read_model jsonb;

  v_resolution_plan public.commercial_secret_resolution_plans;
  v_resolution_replay public.commercial_secret_resolution_plans;
  v_resolution_plan_evaluated public.commercial_secret_resolution_plans;
  v_resolution_plan_built public.commercial_secret_resolution_plans;
  v_resolution_lease public.commercial_secret_resolution_leases;
  v_resolution_step public.commercial_secret_resolution_steps;
  v_orchestration_attempt public.commercial_secret_resolution_attempts;
  v_orchestrator_read_model public.commercial_secret_resolution_plan_read_model;

  v_provider_code text := 'MIGRATION_126_PROVIDER_' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,12));
  v_adapter_key text := 'migration_126_noop_' || lower(substr(replace(gen_random_uuid()::text,'-',''),1,12));
  v_profile_key text := 'migration_126:credential:' || lower(substr(replace(gen_random_uuid()::text,'-',''),1,16));
  v_binding_key text := 'migration_126:binding:' || lower(substr(replace(gen_random_uuid()::text,'-',''),1,16));
  v_request_key text := 'migration_126:request:' || lower(substr(replace(gen_random_uuid()::text,'-',''),1,16));
  v_idempotency_key text := 'migration_126:idempotency:' || lower(substr(replace(gen_random_uuid()::text,'-',''),1,16));
  v_reference text := 'vault://migration-126/' || lower(substr(replace(gen_random_uuid()::text,'-',''),1,24));
  v_fingerprint text := encode(extensions.digest(gen_random_uuid()::text,'sha256'),'hex');
  v_resolution_plan_key text := 'migration_126:resolution_plan:' || lower(substr(replace(gen_random_uuid()::text,'-',''),1,16));
  v_resolution_idempotency_key text := 'migration_126:resolution_idempotency:' || lower(substr(replace(gen_random_uuid()::text,'-',''),1,16));
  v_resolution_correlation_id uuid := gen_random_uuid();

  v_purchase_before bigint; v_purchase_after bigint;
  v_checkout_before bigint; v_checkout_after bigint;
  v_provider_request_before bigint; v_provider_request_after bigint;
  v_callback_before bigint; v_callback_after bigint;
  v_reconciliation_before bigint; v_reconciliation_after bigint;
  v_wallet_before bigint; v_wallet_after bigint;
  v_ledger_before bigint; v_ledger_after bigint;
  v_outbox_before bigint; v_outbox_after bigint;

  v_profile_count bigint; v_version_count bigint; v_binding_count bigint;
  v_request_count bigint; v_attempt_count bigint; v_receipt_count bigint; v_event_count bigint;
  v_resolution_plan_count bigint; v_resolution_step_count bigint;
  v_resolution_idempotency_count bigint; v_resolution_lease_count bigint;
  v_orchestration_attempt_count bigint; v_orchestration_receipt_count bigint;
  v_orchestration_event_count bigint;

  v_idempotency_conflict_guard boolean := false;
  v_policy_guard boolean := false;
  v_profile_guard boolean := false;
  v_version_guard boolean := false;
  v_receipt_guard boolean := false;
  v_event_guard boolean := false;
  v_plaintext_guard boolean := false;
  v_resolution_guard boolean := false;
  v_decryption_guard boolean := false;
  v_delivery_guard boolean := false;
  v_network_guard boolean := false;
  v_adapter_policy_temporarily_approved boolean := false;
  v_credential_policy_temporarily_approved boolean := false;
  v_resolution_idempotency_conflict_guard boolean := false;
  v_orchestrator_policy_guard boolean := false;
  v_orchestrator_receipt_guard boolean := false;
  v_orchestrator_event_guard boolean := false;
  v_orchestrator_plaintext_guard boolean := false;
  v_lease_claim_guard boolean := false;
  v_backend_contact_guard boolean := false;
  v_material_loading_guard boolean := false;
  v_orchestrator_delivery_guard boolean := false;
  v_orchestrator_network_guard boolean := false;
begin
  if to_regclass('public.commercial_provider_credential_policies') is null
     or to_regclass('public.commercial_provider_credential_profiles') is null
     or to_regclass('public.commercial_provider_credential_versions') is null
     or to_regclass('public.commercial_provider_credential_bindings') is null
     or to_regclass('public.commercial_provider_credential_access_requests') is null
     or to_regclass('public.commercial_provider_credential_resolution_attempts') is null
     or to_regclass('public.commercial_provider_credential_receipts') is null
     or to_regclass('public.commercial_provider_credential_events') is null then
    raise exception 'MIGRATION_126_REQUIRES_MIGRATION_122';
  end if;

  if to_regprocedure('public.record_blocked_provider_credential_resolution_internal(uuid,text,text)') is null then
    raise exception 'MIGRATION_126_REQUIRES_MIGRATION_123';
  end if;

  if to_regclass('public.commercial_secret_resolution_policies') is null
     or to_regclass('public.commercial_secret_resolution_plans') is null
     or to_regclass('public.commercial_secret_resolution_steps') is null
     or to_regclass('public.commercial_secret_resolution_idempotency') is null
     or to_regclass('public.commercial_secret_resolution_leases') is null
     or to_regclass('public.commercial_secret_resolution_attempts') is null
     or to_regclass('public.commercial_secret_resolution_receipts') is null
     or to_regclass('public.commercial_secret_resolution_events') is null
     or to_regclass('public.commercial_secret_resolution_plan_read_model') is null
     or to_regprocedure('public.enqueue_commercial_secret_resolution_plan(text,text,uuid,text,uuid,uuid,jsonb)') is null
     or to_regprocedure('public.evaluate_commercial_secret_resolution_plan(uuid,text)') is null
     or to_regprocedure('public.build_commercial_secret_resolution_plan(uuid,text)') is null
     or to_regprocedure('public.offer_commercial_secret_resolution_lease(uuid,text)') is null
     or to_regprocedure('public.record_blocked_secret_resolution_attempt(uuid,uuid,text,text)') is null then
    raise exception 'MIGRATION_126_REQUIRES_MIGRATION_125';
  end if;

  select count(*) into v_purchase_before from public.commercial_purchases;
  select count(*) into v_checkout_before from public.commercial_checkout_sessions;
  select count(*) into v_provider_request_before from public.commercial_checkout_provider_requests;
  select count(*) into v_callback_before from public.commercial_checkout_callbacks;
  select count(*) into v_reconciliation_before from public.commercial_checkout_reconciliation_observations;
  select count(*) into v_wallet_before from public.commercial_wallets;
  select count(*) into v_ledger_before from public.commercial_ledger;
  select count(*) into v_outbox_before from public.commercial_purchase_runtime_outbox;

  -- ===========================================================================
  -- 3. TEMPORARILY APPROVE PASSIVE ADAPTER POLICY
  -- ===========================================================================

  select *
  into strict v_adapter_policy
  from public.commercial_provider_adapter_policies
  where policy_code = 'DEFAULT_PROVIDER_ADAPTER_CONTRACT'
    and environment = 'test'
  order by version_number desc
  limit 1;

  if v_adapter_policy.policy_status <> 'approved' then
    update public.commercial_provider_adapter_policies
    set
      policy_status = 'approved',
      approved_by = 'MIGRATION_126',
      approved_at = clock_timestamp()
    where id = v_adapter_policy.id
    returning * into v_adapter_policy;

    v_adapter_policy_temporarily_approved := true;
  end if;

  if v_adapter_policy.adapter_execution_enabled
     or v_adapter_policy.network_access_enabled
     or v_adapter_policy.credential_resolution_enabled
     or v_adapter_policy.callback_verification_enabled
     or v_adapter_policy.automatic_binding_activation_enabled then
    raise exception 'MIGRATION_126_UNSAFE_ADAPTER_POLICY';
  end if;

  -- ===========================================================================
  -- 5. CREATE TEMPORARY PROVIDER
  -- ===========================================================================

  insert into public.commercial_providers (
    provider_code,
    display_name,
    provider_type,
    ownership_type,
    integration_mode,
    adapter_key,
    enabled,
    public,
    test_mode,
    configuration,
    metadata,
    version
  ) values (
    v_provider_code,
    'Migration 124 Temporary Provider',
    'payment_gateway',
    'external',
    'adapter',
    v_adapter_key,
    false,
    false,
    true,
    jsonb_build_object(
      'mode', 'certification_only',
      'external_calls', false,
      'credentials_present', false
    ),
    jsonb_build_object(
      'temporary', true,
      'certification', 'MIGRATION_126'
    ),
    1
  )
  returning * into v_provider;

  raise notice
    'MIGRATION_126_TEMPORARY_PROVIDER_CREATED provider_id=%, provider_code=%, adapter_key=%',
    v_provider.id,
    v_provider.provider_code,
    v_provider.adapter_key;

  -- ===========================================================================
  -- 6. REGISTER ADAPTER CONTRACT AND VERSION
  -- ===========================================================================

  v_contract :=
    public.register_commercial_provider_adapter_contract_internal(
      v_adapter_key,
      'Migration 124 No-op Gateway Adapter',
      'payment_gateway',
      'MIGRATION_126',
      jsonb_build_object(
        'temporary', true,
        'certification', 'MIGRATION_126',
        'external_calls', false
      )
    );

  v_version :=
    public.create_commercial_provider_adapter_version_internal(
      v_contract.id,
      jsonb_build_object(
        'type', 'object',
        'required', jsonb_build_array(
          'operation_code',
          'idempotency_key',
          'correlation_id',
          'payload'
        ),
        'additionalProperties', false
      ),
      jsonb_build_object(
        'type', 'object',
        'required', jsonb_build_array(
          'provider_reference',
          'provider_status',
          'payload'
        ),
        'additionalProperties', false
      ),
      jsonb_build_object(
        'type', 'object',
        'required', jsonb_build_array(
          'provider_event_id',
          'provider_event_type',
          'payload'
        ),
        'additionalProperties', false
      ),
      jsonb_build_object(
        'type', 'object',
        'required', jsonb_build_array(
          'normalized_error_code',
          'error_category',
          'retry_class'
        ),
        'additionalProperties', false
      ),
      'Migration 124 execution gateway lifecycle certification',
      'MIGRATION_126',
      jsonb_build_object(
        'temporary', true,
        'network_accessed', false,
        'credentials_resolved', false
      )
    );

  -- ===========================================================================
  -- 7. DECLARE FOUR CANONICAL OPERATIONS
  -- ===========================================================================

  v_create_operation :=
    public.declare_commercial_provider_adapter_operation_internal(
      v_version.id,
      'CREATE_CHECKOUT',
      'outbound',
      'create_checkout',
      true,
      true,
      true,
      jsonb_build_object(
        'type', 'object',
        'required', jsonb_build_array(
          'purchase_id',
          'amount_minor',
          'currency',
          'idempotency_key'
        )
      ),
      jsonb_build_object(
        'type', 'object',
        'required', jsonb_build_array(
          'provider_checkout_id',
          'checkout_status'
        )
      ),
      15000,
      'MIGRATION_126',
      jsonb_build_object('dispatch_enabled', false)
    );

  v_operation :=
    public.declare_commercial_provider_adapter_operation_internal(
      v_version.id,
      'RETRIEVE_CHECKOUT',
      'outbound',
      'retrieve_checkout',
      true,
      false,
      true,
      jsonb_build_object(
        'type', 'object',
        'required', jsonb_build_array('provider_checkout_id')
      ),
      jsonb_build_object(
        'type', 'object',
        'required', jsonb_build_array('checkout_status')
      ),
      15000,
      'MIGRATION_126',
      jsonb_build_object('dispatch_enabled', false)
    );

  v_operation :=
    public.declare_commercial_provider_adapter_operation_internal(
      v_version.id,
      'VERIFY_CALLBACK',
      'inbound',
      'verify_callback',
      false,
      true,
      false,
      jsonb_build_object(
        'type', 'object',
        'required', jsonb_build_array('headers', 'raw_body')
      ),
      jsonb_build_object(
        'type', 'object',
        'required', jsonb_build_array('verified')
      ),
      10000,
      'MIGRATION_126',
      jsonb_build_object('verification_enabled', false)
    );

  v_operation :=
    public.declare_commercial_provider_adapter_operation_internal(
      v_version.id,
      'NORMALIZE_CALLBACK',
      'inbound',
      'normalize_callback',
      false,
      true,
      false,
      jsonb_build_object(
        'type', 'object',
        'required', jsonb_build_array('provider_payload')
      ),
      jsonb_build_object(
        'type', 'object',
        'required', jsonb_build_array(
          'provider_event_id',
          'normalized_event_type'
        )
      ),
      10000,
      'MIGRATION_126',
      jsonb_build_object('processing_enabled', false)
    );

  -- ===========================================================================
  -- 8. ERROR MAPPINGS, VALIDATION AND APPROVAL
  -- ===========================================================================

  v_error_mapping :=
    public.map_commercial_provider_adapter_error_internal(
      v_version.id,
      'provider_timeout',
      'COMMERCIAL_PROVIDER_TIMEOUT',
      'timeout',
      'backoff',
      'error',
      'commercial.provider.timeout',
      'MIGRATION_126',
      jsonb_build_object(
        'temporary', true,
        'certification', 'MIGRATION_126'
      )
    );

  v_error_mapping :=
    public.map_commercial_provider_adapter_error_internal(
      v_version.id,
      'provider_declined',
      'COMMERCIAL_PROVIDER_PAYMENT_DECLINED',
      'payment_declined',
      'never',
      'warning',
      'commercial.provider.payment_declined',
      'MIGRATION_126',
      jsonb_build_object(
        'temporary', true,
        'certification', 'MIGRATION_126'
      )
    );

  v_validation :=
    public.validate_commercial_provider_adapter_version_internal(
      v_version.id,
      'MIGRATION_126',
      jsonb_build_object(
        'certification', 'MIGRATION_126',
        'network_accessed', false,
        'credentials_resolved', false
      )
    );

  if v_validation.validation_status <> 'passed' then
    raise exception
      'MIGRATION_126_ADAPTER_VALIDATION_FAILED status=%, failures=%, warnings=%',
      v_validation.validation_status,
      v_validation.failures,
      v_validation.warnings;
  end if;

  v_version :=
    public.approve_commercial_provider_adapter_version_internal(
      v_version.id,
      'MIGRATION_126',
      'Execution gateway transactional lifecycle certification'
    );

  -- ===========================================================================
  -- 9. CREATE AND VALIDATE PASSIVE BINDING
  -- ===========================================================================

  v_binding :=
    public.create_commercial_provider_adapter_binding_internal(
      v_provider.id,
      null,
      v_version.id,
      v_adapter_policy.id,
      'MIGRATION_126',
      jsonb_build_object(
        'mode', 'certification_only',
        'network_access', false,
        'credential_resolution', false
      ),
      jsonb_build_object(
        'temporary', true,
        'certification', 'MIGRATION_126'
      )
    );

  v_binding :=
    public.evaluate_commercial_provider_adapter_binding_internal(
      v_binding.id,
      'MIGRATION_126'
    );

  if v_binding.binding_status <> 'validated'
     or v_binding.readiness_status <> 'ready'
     or coalesce((v_binding.readiness_report->>'validated_without_provider_call')::boolean, false) is not true
     or coalesce((v_binding.readiness_report->>'execution_enabled')::boolean, true) is not false
     or coalesce((v_binding.readiness_report->>'network_access_enabled')::boolean, true) is not false
     or coalesce((v_binding.readiness_report->>'credential_resolution_enabled')::boolean, true) is not false then
    raise exception
      'MIGRATION_126_BINDING_READINESS_FAILED status=%, readiness=%, report=%',
      v_binding.binding_status,
      v_binding.readiness_status,
      v_binding.readiness_report;
  end if;



  select * into strict v_credential_policy
  from public.commercial_provider_credential_policies
  where policy_code='DEFAULT_PROVIDER_CREDENTIAL_VAULT' and environment='test'
  order by version_number desc limit 1;

  if v_credential_policy.policy_status <> 'approved' then
    update public.commercial_provider_credential_policies
    set policy_status='approved', approved_by='MIGRATION_126', approved_at=clock_timestamp()
    where id=v_credential_policy.id returning * into v_credential_policy;
    v_credential_policy_temporarily_approved := true;
  end if;

  if v_credential_policy.secret_resolution_enabled
     or v_credential_policy.secret_decryption_enabled
     or v_credential_policy.credential_delivery_enabled
     or v_credential_policy.automatic_rotation_enabled
     or v_credential_policy.network_access_enabled then
    raise exception 'MIGRATION_126_UNSAFE_CREDENTIAL_POLICY';
  end if;

  v_profile := public.register_commercial_provider_credential_profile_internal(
    v_profile_key,
    'Migration 124 Temporary Credential',
    'api_key',
    'test',
    'adapter_binding',
    v_provider.id,
    v_binding.id,
    array['checkout:create']::text[],
    array['create_checkout']::text[],
    'MIGRATION_126',
    jsonb_build_object('temporary',true,'certification','MIGRATION_126')
  );

  v_credential_version := public.create_commercial_provider_credential_version_internal(
    v_profile.id,
    'external_reference',
    v_reference,
    v_fingerprint,
    clock_timestamp(),
    clock_timestamp() + interval '180 days',
    clock_timestamp() + interval '60 days',
    array['checkout:create']::text[],
    'MIGRATION_126',
    jsonb_build_object('temporary',true,'certification','MIGRATION_126')
  );

  if v_credential_version.secret_reference_hash <> encode(extensions.digest(v_reference,'sha256'),'hex')
     or v_credential_version.material_fingerprint <> v_fingerprint then
    raise exception 'MIGRATION_126_REFERENCE_HASH_OR_FINGERPRINT_FAILED';
  end if;

  v_profile := public.approve_commercial_provider_credential_profile_internal(v_profile.id,'MIGRATION_126');
  v_credential_version := public.approve_commercial_provider_credential_version_internal(v_credential_version.id,'MIGRATION_126');

  v_credential_binding := public.create_commercial_provider_credential_binding_internal(
    v_profile.id,
    v_credential_version.id,
    v_provider.id,
    v_binding.id,
    v_credential_policy.id,
    v_binding_key,
    array['checkout:create']::text[],
    array['create_checkout']::text[],
    'MIGRATION_126',
    jsonb_build_object('temporary',true,'certification','MIGRATION_126')
  );

  v_credential_binding := public.evaluate_commercial_provider_credential_binding_internal(
    v_credential_binding.id,'MIGRATION_126'
  );

  if v_credential_binding.binding_status <> 'validated'
     or v_credential_binding.readiness_status <> 'ready'
     or coalesce((v_credential_binding.readiness_report->>'validated_without_secret_access')::boolean,false) is not true
     or coalesce((v_credential_binding.readiness_report->>'secret_resolution_enabled')::boolean,true)
     or coalesce((v_credential_binding.readiness_report->>'secret_decryption_enabled')::boolean,true)
     or coalesce((v_credential_binding.readiness_report->>'credential_delivery_enabled')::boolean,true)
     or coalesce((v_credential_binding.readiness_report->>'network_access_enabled')::boolean,true) then
    raise exception 'MIGRATION_126_BINDING_VALIDATION_FAILED report=%',v_credential_binding.readiness_report;
  end if;

  v_request := public.request_commercial_provider_credential_access_internal(
    v_request_key,
    v_idempotency_key,
    v_credential_binding.id,
    null,
    array['checkout:create']::text[],
    'create_checkout',
    120,
    'MIGRATION_126',
    gen_random_uuid(),
    null,
    jsonb_build_object('temporary',true,'certification','MIGRATION_126')
  );

  v_replay := public.request_commercial_provider_credential_access_internal(
    v_request_key,
    v_idempotency_key,
    v_credential_binding.id,
    null,
    array['checkout:create']::text[],
    'create_checkout',
    120,
    'MIGRATION_126_REPLAY',
    gen_random_uuid(),
    null,
    jsonb_build_object('temporary',true,'certification','MIGRATION_126')
  );

  if v_replay.id <> v_request.id then
    raise exception 'MIGRATION_126_IDEMPOTENCY_REPLAY_FAILED';
  end if;

  begin
    perform public.request_commercial_provider_credential_access_internal(
      v_request_key,v_idempotency_key,v_credential_binding.id,null,
      array['checkout:create','checkout:read']::text[],'create_checkout',120,
      'MIGRATION_126_CONFLICT',gen_random_uuid(),null,
      jsonb_build_object('temporary',true,'certification','MIGRATION_126')
    );
    raise exception 'MIGRATION_126_IDEMPOTENCY_CONFLICT_GUARD_NOT_ENFORCED';
  exception when others then
    if sqlerrm='COMMERCIAL_PROVIDER_CREDENTIAL_ACCESS_IDEMPOTENCY_CONFLICT' then
      v_idempotency_conflict_guard := true;
    else raise;
    end if;
  end;

  v_request := public.evaluate_commercial_provider_credential_access_internal(v_request.id,'MIGRATION_126');

  if v_request.request_status <> 'held'
     or v_request.terminal_reason <> 'FOUNDATION_CREDENTIAL_RESOLUTION_DISABLED'
     or v_request.evaluated_at is null
     or v_request.held_at is null then
    raise exception 'MIGRATION_126_REQUEST_HOLD_FAILED status=%, reason=%',v_request.request_status,v_request.terminal_reason;
  end if;

  v_attempt := public.record_blocked_provider_credential_resolution_internal(
    v_request.id,'MIGRATION_126','FOUNDATION_CREDENTIAL_RESOLUTION_DISABLED'
  );

  if v_attempt.attempt_status <> 'blocked'
     or v_attempt.backend_contact_requested
     or v_attempt.backend_contact_performed
     or v_attempt.decryption_requested
     or v_attempt.decryption_performed
     or v_attempt.credential_material_loaded
     or v_attempt.credential_material_delivered
     or v_attempt.started_at is not null then
    raise exception 'MIGRATION_126_BLOCKED_RESOLUTION_ATTEMPT_FAILED';
  end if;


  -- ===========================================================================
  -- SECRET RESOLUTION ORCHESTRATOR LIFECYCLE
  -- ===========================================================================

  v_resolution_plan := public.enqueue_commercial_secret_resolution_plan(
    v_resolution_plan_key,
    v_resolution_idempotency_key,
    v_request.id,
    'MIGRATION_126',
    v_resolution_correlation_id,
    null,
    jsonb_build_object('temporary',true,'certification','MIGRATION_126')
  );

  v_resolution_replay := public.enqueue_commercial_secret_resolution_plan(
    v_resolution_plan_key,
    v_resolution_idempotency_key,
    v_request.id,
    'MIGRATION_126_REPLAY',
    v_resolution_correlation_id,
    null,
    jsonb_build_object('temporary',true,'certification','MIGRATION_126')
  );

  if v_resolution_replay.id <> v_resolution_plan.id then
    raise exception 'MIGRATION_126_RESOLUTION_IDEMPOTENCY_REPLAY_FAILED';
  end if;

  begin
    perform public.enqueue_commercial_secret_resolution_plan(
      v_resolution_plan_key,
      v_resolution_idempotency_key,
      v_request.id,
      'MIGRATION_126_CONFLICT',
      v_resolution_correlation_id,
      null,
      jsonb_build_object('temporary',true,'certification','MIGRATION_126','changed',true)
    );
    raise exception 'MIGRATION_126_RESOLUTION_IDEMPOTENCY_CONFLICT_GUARD_NOT_ENFORCED';
  exception when others then
    if sqlerrm='COMMERCIAL_SECRET_RESOLUTION_IDEMPOTENCY_CONFLICT' then
      v_resolution_idempotency_conflict_guard := true;
    else
      raise;
    end if;
  end;

  v_resolution_plan_evaluated :=
    public.evaluate_commercial_secret_resolution_plan(
      v_resolution_plan.id,
      'MIGRATION_126'
    );

  if v_resolution_plan_evaluated.plan_status <> 'evaluated'
     or v_resolution_plan_evaluated.evaluated_at is null then
    raise exception
      'MIGRATION_126_RESOLUTION_EVALUATION_FAILED status=%',
      v_resolution_plan_evaluated.plan_status;
  end if;

  v_resolution_plan_built :=
    public.build_commercial_secret_resolution_plan(
      v_resolution_plan.id,
      'MIGRATION_126'
    );

  if v_resolution_plan_built.plan_status <> 'planned'
     or v_resolution_plan_built.planned_at is null then
    raise exception
      'MIGRATION_126_RESOLUTION_PLAN_BUILD_FAILED status=%',
      v_resolution_plan_built.plan_status;
  end if;

  select *
  into strict v_resolution_step
  from public.commercial_secret_resolution_steps
  where resolution_plan_id = v_resolution_plan.id
    and step_number = 3;

  if exists (
    select 1
    from public.commercial_secret_resolution_steps
    where resolution_plan_id = v_resolution_plan.id
      and (
        requires_backend_contact
        or requires_decryption
        or requires_material_loading
        or requires_delivery
        or requires_network
      )
  ) then
    raise exception 'MIGRATION_126_UNSAFE_RESOLUTION_STEP_CREATED';
  end if;

  v_resolution_lease :=
    public.offer_commercial_secret_resolution_lease(
      v_resolution_plan.id,
      'MIGRATION_126'
    );

  if v_resolution_lease.lease_status <> 'offered'
     or v_resolution_lease.lease_owner is not null
     or v_resolution_lease.lease_token_hash is not null
     or v_resolution_lease.claimed_at is not null
     or v_resolution_lease.expires_at is not null then
    raise exception 'MIGRATION_126_PASSIVE_LEASE_ASSERTION_FAILED';
  end if;

  select *
  into strict v_resolution_plan
  from public.commercial_secret_resolution_plans
  where id = v_resolution_plan.id;

  if v_resolution_plan.plan_status <> 'held'
     or v_resolution_plan.terminal_reason <> 'AUTOMATIC_DISPATCH_DISABLED'
     or v_resolution_plan.held_at is null then
    raise exception
      'MIGRATION_126_RESOLUTION_PLAN_HOLD_FAILED status=%, reason=%',
      v_resolution_plan.plan_status,
      v_resolution_plan.terminal_reason;
  end if;

  v_orchestration_attempt :=
    public.record_blocked_secret_resolution_attempt(
      v_resolution_plan.id,
      v_resolution_step.id,
      'MIGRATION_126',
      'PASSIVE_FOUNDATION_EXECUTION_DISABLED'
    );

  if v_orchestration_attempt.attempt_status <> 'blocked'
     or v_orchestration_attempt.dispatch_requested
     or v_orchestration_attempt.dispatch_performed
     or v_orchestration_attempt.backend_contact_requested
     or v_orchestration_attempt.backend_contact_performed
     or v_orchestration_attempt.resolution_requested
     or v_orchestration_attempt.resolution_performed
     or v_orchestration_attempt.decryption_requested
     or v_orchestration_attempt.decryption_performed
     or v_orchestration_attempt.material_loaded
     or v_orchestration_attempt.material_delivered
     or v_orchestration_attempt.network_attempted then
    raise exception 'MIGRATION_126_BLOCKED_ORCHESTRATION_ATTEMPT_FAILED';
  end if;

  select *
  into strict v_orchestrator_read_model
  from public.commercial_secret_resolution_plan_read_model
  where resolution_plan_id = v_resolution_plan.id;

  if v_orchestrator_read_model.plan_status <> 'held'
     or v_orchestrator_read_model.step_count <> 3
     or v_orchestrator_read_model.attempt_count <> 1
     or v_orchestrator_read_model.receipt_count <> 4
     or v_orchestrator_read_model.event_count <> 5
     or v_orchestrator_read_model.automatic_dispatch_enabled
     or v_orchestrator_read_model.secret_backend_contact_enabled
     or v_orchestrator_read_model.secret_resolution_enabled
     or v_orchestrator_read_model.secret_decryption_enabled
     or v_orchestrator_read_model.credential_material_loading_enabled
     or v_orchestrator_read_model.credential_delivery_enabled
     or v_orchestrator_read_model.network_access_enabled then
    raise exception
      'MIGRATION_126_ORCHESTRATOR_READ_MODEL_FAILED status=%, steps=%, attempts=%, receipts=%, events=%',
      v_orchestrator_read_model.plan_status,
      v_orchestrator_read_model.step_count,
      v_orchestrator_read_model.attempt_count,
      v_orchestrator_read_model.receipt_count,
      v_orchestrator_read_model.event_count;
  end if;

  begin
    update public.commercial_secret_resolution_policies
    set maximum_plan_attempts = maximum_plan_attempts + 1
    where id = v_resolution_plan.orchestrator_policy_id;
    raise exception 'MIGRATION_126_ORCHESTRATOR_POLICY_GUARD_NOT_ENFORCED';
  exception when others then
    if sqlerrm='COMMERCIAL_SECRET_RESOLUTION_POLICY_IMMUTABLE' then
      v_orchestrator_policy_guard:=true;
    else
      raise;
    end if;
  end;

  begin
    update public.commercial_secret_resolution_receipts
    set receipt_status='accepted'
    where resolution_plan_id=v_resolution_plan.id;
    raise exception 'MIGRATION_126_ORCHESTRATOR_RECEIPT_GUARD_NOT_ENFORCED';
  exception when others then
    if sqlerrm='COMMERCIAL_SECRET_RESOLUTION_RECEIPT_APPEND_ONLY' then
      v_orchestrator_receipt_guard:=true;
    else
      raise;
    end if;
  end;

  begin
    delete from public.commercial_secret_resolution_events
    where resolution_plan_id=v_resolution_plan.id;
    raise exception 'MIGRATION_126_ORCHESTRATOR_EVENT_GUARD_NOT_ENFORCED';
  exception when others then
    if sqlerrm='COMMERCIAL_SECRET_RESOLUTION_EVENT_APPEND_ONLY' then
      v_orchestrator_event_guard:=true;
    else
      raise;
    end if;
  end;

  begin
    insert into public.commercial_secret_resolution_steps(
      resolution_plan_id,step_number,step_type,step_status,
      requires_backend_contact,maximum_attempts,planned_by,step_metadata
    ) values (
      v_resolution_plan.id,99,'contact_backend','planned',
      true,1,'MIGRATION_126',jsonb_build_object('passive',true)
    );
    raise exception 'MIGRATION_126_BACKEND_CONTACT_GUARD_NOT_ENFORCED';
  exception when check_violation then
    v_backend_contact_guard:=true;
  end;

  begin
    insert into public.commercial_secret_resolution_steps(
      resolution_plan_id,step_number,step_type,step_status,
      requires_material_loading,maximum_attempts,planned_by,step_metadata
    ) values (
      v_resolution_plan.id,98,'load_material','planned',
      true,1,'MIGRATION_126',jsonb_build_object('passive',true)
    );
    raise exception 'MIGRATION_126_MATERIAL_LOADING_GUARD_NOT_ENFORCED';
  exception when check_violation then
    v_material_loading_guard:=true;
  end;

  begin
    insert into public.commercial_secret_resolution_steps(
      resolution_plan_id,step_number,step_type,step_status,
      requires_delivery,maximum_attempts,planned_by,step_metadata
    ) values (
      v_resolution_plan.id,97,'deliver_material','planned',
      true,1,'MIGRATION_126',jsonb_build_object('passive',true)
    );
    raise exception 'MIGRATION_126_ORCHESTRATOR_DELIVERY_GUARD_NOT_ENFORCED';
  exception when check_violation then
    v_orchestrator_delivery_guard:=true;
  end;

  begin
    insert into public.commercial_secret_resolution_steps(
      resolution_plan_id,step_number,step_type,step_status,
      requires_network,maximum_attempts,planned_by,step_metadata
    ) values (
      v_resolution_plan.id,96,'contact_backend','planned',
      true,1,'MIGRATION_126',jsonb_build_object('passive',true)
    );
    raise exception 'MIGRATION_126_ORCHESTRATOR_NETWORK_GUARD_NOT_ENFORCED';
  exception when check_violation then
    v_orchestrator_network_guard:=true;
  end;

  begin
    update public.commercial_secret_resolution_leases
    set lease_status='claimed',
        lease_owner='MIGRATION_126',
        claimed_at=clock_timestamp(),
        expires_at=clock_timestamp()+interval '30 seconds'
    where id=v_resolution_lease.id;
    raise exception 'MIGRATION_126_LEASE_CLAIM_GUARD_NOT_ENFORCED';
  exception when check_violation then
    v_lease_claim_guard:=true;
  end;

  begin
    insert into public.commercial_secret_resolution_receipts(
      resolution_plan_id,receipt_type,receipt_status,normalized_payload,
      content_hash,issued_by,correlation_id,metadata
    ) values (
      v_resolution_plan.id,'execution_blocked','blocked',
      jsonb_build_object('api_key','forbidden-plaintext'),
      repeat('a',64),'MIGRATION_126',v_resolution_correlation_id,'{}'::jsonb
    );
    raise exception 'MIGRATION_126_ORCHESTRATOR_PLAINTEXT_GUARD_NOT_ENFORCED';
  exception when check_violation then
    v_orchestrator_plaintext_guard:=true;
  end;

  begin
    update public.commercial_provider_credential_policies set maximum_access_ttl_seconds=301 where id=v_credential_policy.id;
    raise exception 'MIGRATION_126_POLICY_GUARD_NOT_ENFORCED';
  exception when others then
    if sqlerrm='COMMERCIAL_PROVIDER_CREDENTIAL_POLICY_IMMUTABLE' then v_policy_guard:=true; else raise; end if;
  end;

  begin
    update public.commercial_provider_credential_profiles set display_name='Mutation forbidden' where id=v_profile.id;
    raise exception 'MIGRATION_126_PROFILE_GUARD_NOT_ENFORCED';
  exception when others then
    if sqlerrm='COMMERCIAL_PROVIDER_CREDENTIAL_PROFILE_IMMUTABLE' then v_profile_guard:=true; else raise; end if;
  end;

  begin
    update public.commercial_provider_credential_versions set secret_reference='vault://forbidden/mutation' where id=v_credential_version.id;
    raise exception 'MIGRATION_126_VERSION_GUARD_NOT_ENFORCED';
  exception when others then
    if sqlerrm='COMMERCIAL_PROVIDER_CREDENTIAL_VERSION_IMMUTABLE' then v_version_guard:=true; else raise; end if;
  end;

  begin
    update public.commercial_provider_credential_receipts set receipt_status='accepted' where access_request_id=v_request.id;
    raise exception 'MIGRATION_126_RECEIPT_GUARD_NOT_ENFORCED';
  exception when others then
    if sqlerrm='COMMERCIAL_PROVIDER_CREDENTIAL_RECEIPT_APPEND_ONLY' then v_receipt_guard:=true; else raise; end if;
  end;

  begin
    delete from public.commercial_provider_credential_events where access_request_id=v_request.id;
    raise exception 'MIGRATION_126_EVENT_GUARD_NOT_ENFORCED';
  exception when others then
    if sqlerrm='COMMERCIAL_PROVIDER_CREDENTIAL_EVENT_APPEND_ONLY' then v_event_guard:=true; else raise; end if;
  end;

  begin
    insert into public.commercial_provider_credential_profiles(
      credential_key,display_name,credential_type,environment,profile_status,owner_scope,
      provider_id,adapter_binding_id,metadata,created_by
    ) values (
      'migration_126:plaintext_probe','Plaintext Probe','api_key','test','draft','provider',
      v_provider.id,null,jsonb_build_object('api_key','forbidden-plaintext'),'MIGRATION_126'
    );
    raise exception 'MIGRATION_126_PLAINTEXT_GUARD_NOT_ENFORCED';
  exception when check_violation then
    v_plaintext_guard:=true;
  end;

  begin
    update public.commercial_provider_credential_access_requests set request_status='resolving' where id=v_request.id;
    raise exception 'MIGRATION_126_RESOLUTION_GUARD_NOT_ENFORCED';
  exception when check_violation then v_resolution_guard:=true;
  end;

  begin
    insert into public.commercial_provider_credential_resolution_attempts(
      access_request_id,attempt_number,attempt_status,backend_contact_requested,decryption_requested
    ) values (v_request.id,99,'started',true,false);
    raise exception 'MIGRATION_126_NETWORK_GUARD_NOT_ENFORCED';
  exception when check_violation then v_network_guard:=true;
  end;

  begin
    insert into public.commercial_provider_credential_resolution_attempts(
      access_request_id,attempt_number,attempt_status,decryption_requested
    ) values (v_request.id,98,'started',true);
    raise exception 'MIGRATION_126_DECRYPTION_GUARD_NOT_ENFORCED';
  exception when check_violation then v_decryption_guard:=true;
  end;

  begin
    insert into public.commercial_provider_credential_resolution_attempts(
      access_request_id,attempt_number,attempt_status,credential_material_delivered
    ) values (v_request.id,97,'resolved',true);
    raise exception 'MIGRATION_126_DELIVERY_GUARD_NOT_ENFORCED';
  exception when check_violation then v_delivery_guard:=true;
  end;

  v_read_model := public.get_commercial_provider_credential_access_internal(v_request.id);
  if v_read_model is null
     or v_read_model->'access_request'->>'request_status' <> 'held'
     or jsonb_array_length(v_read_model->'attempts') <> 1
     or jsonb_array_length(v_read_model->'receipts') <> 2 then
    raise exception 'MIGRATION_126_READ_MODEL_FAILED payload=%',v_read_model;
  end if;

  select count(*) into v_profile_count from public.commercial_provider_credential_profiles where id=v_profile.id;
  select count(*) into v_version_count from public.commercial_provider_credential_versions where id=v_credential_version.id;
  select count(*) into v_binding_count from public.commercial_provider_credential_bindings where id=v_credential_binding.id;
  select count(*) into v_request_count from public.commercial_provider_credential_access_requests where id=v_request.id;
  select count(*) into v_attempt_count from public.commercial_provider_credential_resolution_attempts where access_request_id=v_request.id;
  select count(*) into v_receipt_count from public.commercial_provider_credential_receipts where access_request_id=v_request.id;
  select count(*) into v_event_count from public.commercial_provider_credential_events
    where credential_profile_id=v_profile.id or access_request_id=v_request.id;

  select count(*) into v_resolution_plan_count
  from public.commercial_secret_resolution_plans
  where id=v_resolution_plan.id;

  select count(*) into v_resolution_step_count
  from public.commercial_secret_resolution_steps
  where resolution_plan_id=v_resolution_plan.id;

  select count(*) into v_resolution_idempotency_count
  from public.commercial_secret_resolution_idempotency
  where resolution_plan_id=v_resolution_plan.id;

  select count(*) into v_resolution_lease_count
  from public.commercial_secret_resolution_leases
  where resolution_plan_id=v_resolution_plan.id;

  select count(*) into v_orchestration_attempt_count
  from public.commercial_secret_resolution_attempts
  where resolution_plan_id=v_resolution_plan.id;

  select count(*) into v_orchestration_receipt_count
  from public.commercial_secret_resolution_receipts
  where resolution_plan_id=v_resolution_plan.id;

  select count(*) into v_orchestration_event_count
  from public.commercial_secret_resolution_events
  where resolution_plan_id=v_resolution_plan.id;

  if v_profile_count<>1 or v_version_count<>1 or v_binding_count<>1 or v_request_count<>1
     or v_attempt_count<>1 or v_receipt_count<>2 or v_event_count<8 then
    raise exception 'MIGRATION_126_LIFECYCLE_COUNT_FAILED profile=%, version=%, binding=%, request=%, attempt=%, receipt=%, event=%',
      v_profile_count,v_version_count,v_binding_count,v_request_count,v_attempt_count,v_receipt_count,v_event_count;
  end if;

  if v_resolution_plan_count<>1
     or v_resolution_step_count<>3
     or v_resolution_idempotency_count<>1
     or v_resolution_lease_count<>1
     or v_orchestration_attempt_count<>1
     or v_orchestration_receipt_count<>4
     or v_orchestration_event_count<>5 then
    raise exception
      'MIGRATION_126_ORCHESTRATOR_COUNT_FAILED plan=%, step=%, idempotency=%, lease=%, attempt=%, receipt=%, event=%',
      v_resolution_plan_count,v_resolution_step_count,v_resolution_idempotency_count,
      v_resolution_lease_count,v_orchestration_attempt_count,
      v_orchestration_receipt_count,v_orchestration_event_count;
  end if;

  select count(*) into v_purchase_after from public.commercial_purchases;
  select count(*) into v_checkout_after from public.commercial_checkout_sessions;
  select count(*) into v_provider_request_after from public.commercial_checkout_provider_requests;
  select count(*) into v_callback_after from public.commercial_checkout_callbacks;
  select count(*) into v_reconciliation_after from public.commercial_checkout_reconciliation_observations;
  select count(*) into v_wallet_after from public.commercial_wallets;
  select count(*) into v_ledger_after from public.commercial_ledger;
  select count(*) into v_outbox_after from public.commercial_purchase_runtime_outbox;

  if v_purchase_after<>v_purchase_before or v_checkout_after<>v_checkout_before
     or v_provider_request_after<>v_provider_request_before or v_callback_after<>v_callback_before
     or v_reconciliation_after<>v_reconciliation_before or v_wallet_after<>v_wallet_before
     or v_ledger_after<>v_ledger_before or v_outbox_after<>v_outbox_before then
    raise exception 'MIGRATION_126_ECONOMIC_NON_MUTATION_FAILED';
  end if;

  if not (v_idempotency_conflict_guard and v_policy_guard and v_profile_guard and v_version_guard
          and v_receipt_guard and v_event_guard and v_plaintext_guard and v_resolution_guard
          and v_decryption_guard and v_delivery_guard and v_network_guard
          and v_resolution_idempotency_conflict_guard and v_orchestrator_policy_guard
          and v_orchestrator_receipt_guard and v_orchestrator_event_guard
          and v_orchestrator_plaintext_guard and v_lease_claim_guard
          and v_backend_contact_guard and v_material_loading_guard
          and v_orchestrator_delivery_guard and v_orchestrator_network_guard) then
    raise exception 'MIGRATION_126_GUARD_MATRIX_FAILED';
  end if;

  raise notice 'MIGRATION_126_CERTIFIED provider_count=1, adapter_contract_count=1, adapter_version_count=1, certified_operation_count=4, validated_adapter_binding_count=1, credential_profile_count=1, credential_version_count=1, validated_credential_binding_count=1, access_request_count=1, credential_resolution_attempt_count=1, credential_receipt_count=2, credential_event_count=%, resolution_plan_count=1, resolution_step_count=3, resolution_idempotency_count=1, resolution_lease_count=1, orchestration_attempt_count=1, orchestration_receipt_count=4, orchestration_event_count=5, access_request_status=held, resolution_plan_status=held, idempotency_replay_guard=true, credential_idempotency_conflict_guard=%, resolution_idempotency_conflict_guard=%, credential_policy_guard=%, credential_profile_guard=%, credential_version_guard=%, credential_receipt_guard=%, credential_event_guard=%, orchestrator_policy_guard=%, orchestrator_receipt_guard=%, orchestrator_event_guard=%, plaintext_guard=%, orchestrator_plaintext_guard=%, credential_resolution_guard=%, credential_decryption_guard=%, credential_delivery_guard=%, credential_network_guard=%, lease_claim_guard=%, backend_contact_guard=%, material_loading_guard=%, orchestrator_delivery_guard=%, orchestrator_network_guard=%, automatic_dispatch_enabled=false, secret_backend_contact_enabled=false, secret_resolution_enabled=false, secret_decryption_enabled=false, credential_material_loading_enabled=false, credential_delivery_enabled=false, network_access_enabled=false, purchase_delta=0, checkout_session_delta=0, provider_request_delta=0, callback_delta=0, reconciliation_delta=0, wallet_delta=0, ledger_delta=0, outbox_delta=0, adapter_policy_temporarily_approved=%, credential_policy_temporarily_approved=%, rollback_required=true',
    v_event_count,
    v_idempotency_conflict_guard,
    v_resolution_idempotency_conflict_guard,
    v_policy_guard,
    v_profile_guard,
    v_version_guard,
    v_receipt_guard,
    v_event_guard,
    v_orchestrator_policy_guard,
    v_orchestrator_receipt_guard,
    v_orchestrator_event_guard,
    v_plaintext_guard,
    v_orchestrator_plaintext_guard,
    v_resolution_guard,
    v_decryption_guard,
    v_delivery_guard,
    v_network_guard,
    v_lease_claim_guard,
    v_backend_contact_guard,
    v_material_loading_guard,
    v_orchestrator_delivery_guard,
    v_orchestrator_network_guard,
    v_adapter_policy_temporarily_approved,
    v_credential_policy_temporarily_approved;
end
$$;

rollback;

\echo ''
\echo 'MIGRATION_126_TRANSACTION_ROLLED_BACK'
\echo 'No provider, adapter, credential object, access request, secret-resolution plan, step, lease, attempt, receipt, event, policy approval, checkout record, purchase, wallet, ledger or outbox mutation was persisted.'
