-- =============================================================================
-- FANTAGOL
-- Migration: 118_commercial_provider_adapter_lifecycle_certification.sql
-- Milestone: Commercial Platform - Provider Adapter Lifecycle Certification
--
-- Purpose:
--   Transactionally certify migration 117 through:
--     temporary commercial provider
--     adapter contract registration
--     immutable version creation
--     canonical operation declarations
--     normalized error mapping
--     structural validation
--     version approval
--     passive provider binding
--     binding readiness evaluation
--     immutability / append-only / activation guards
--     economic and checkout non-mutation assertions
--
-- Persistence model:
--   The entire certification runs inside one transaction and ends with ROLLBACK.
-- =============================================================================

\set ON_ERROR_STOP on

begin;

set local statement_timeout = '120s';
set local lock_timeout = '15s';
set local idle_in_transaction_session_timeout = '180s';

do $$
declare
  v_policy public.commercial_provider_adapter_policies;
  v_provider public.commercial_providers;
  v_contract public.commercial_provider_adapter_contracts;
  v_version public.commercial_provider_adapter_versions;
  v_operation public.commercial_provider_adapter_operations;
  v_error_mapping public.commercial_provider_adapter_error_mappings;
  v_validation public.commercial_provider_adapter_validations;
  v_binding public.commercial_provider_adapter_bindings;

  v_provider_code text :=
    'MIGRATION_118_PROVIDER_' ||
    upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));

  v_adapter_key text :=
    'migration_118_noop_' ||
    lower(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));

  v_purchase_before bigint;
  v_purchase_after bigint;
  v_checkout_session_before bigint;
  v_checkout_session_after bigint;
  v_provider_request_before bigint;
  v_provider_request_after bigint;
  v_callback_before bigint;
  v_callback_after bigint;
  v_reconciliation_before bigint;
  v_reconciliation_after bigint;
  v_wallet_before bigint;
  v_wallet_after bigint;
  v_ledger_before bigint;
  v_ledger_after bigint;
  v_outbox_before bigint;
  v_outbox_after bigint;

  v_contract_count bigint;
  v_version_count bigint;
  v_operation_count bigint;
  v_error_count bigint;
  v_validation_count bigint;
  v_binding_count bigint;
  v_event_count bigint;

  v_version_guard boolean := false;
  v_validation_guard boolean := false;
  v_event_guard boolean := false;
  v_policy_guard boolean := false;
  v_binding_activation_guard boolean := false;

  v_policy_temporarily_approved boolean := false;
begin
  -- ===========================================================================
  -- 1. DEPENDENCY ASSERTIONS
  -- ===========================================================================

  if to_regclass('public.commercial_provider_adapter_policies') is null
     or to_regclass('public.commercial_provider_adapter_contracts') is null
     or to_regclass('public.commercial_provider_adapter_versions') is null
     or to_regclass('public.commercial_provider_adapter_operations') is null
     or to_regclass('public.commercial_provider_adapter_error_mappings') is null
     or to_regclass('public.commercial_provider_adapter_bindings') is null
     or to_regclass('public.commercial_provider_adapter_validations') is null
     or to_regclass('public.commercial_provider_adapter_events') is null then
    raise exception 'MIGRATION_118_REQUIRES_MIGRATION_117';
  end if;

  -- ===========================================================================
  -- 2. NON-MUTATION BASELINE
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
  -- 3. TEMPORARILY APPROVE THE PASSIVE FOUNDATION POLICY
  -- ===========================================================================

  select *
  into strict v_policy
  from public.commercial_provider_adapter_policies
  where policy_code = 'DEFAULT_PROVIDER_ADAPTER_CONTRACT'
    and environment = 'test'
  order by version_number desc
  limit 1;

  if v_policy.policy_status <> 'approved' then
    update public.commercial_provider_adapter_policies
    set
      policy_status = 'approved',
      approved_by = 'MIGRATION_118',
      approved_at = clock_timestamp()
    where id = v_policy.id
    returning * into v_policy;

    v_policy_temporarily_approved := true;
  end if;

  if v_policy.adapter_execution_enabled
     or v_policy.network_access_enabled
     or v_policy.credential_resolution_enabled
     or v_policy.callback_verification_enabled
     or v_policy.automatic_binding_activation_enabled then
    raise exception 'MIGRATION_118_UNSAFE_ADAPTER_POLICY';
  end if;

  -- ===========================================================================
  -- 4. CREATE A TEMPORARY PASSIVE PROVIDER
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
    'Migration 118 Temporary Provider',
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
      'certification', 'MIGRATION_118'
    ),
    1
  )
  returning * into v_provider;

  raise notice
    'MIGRATION_118_TEMPORARY_PROVIDER_CREATED provider_id=%, provider_code=%, adapter_key=%',
    v_provider.id,
    v_provider.provider_code,
    v_provider.adapter_key;

  -- ===========================================================================
  -- 5. REGISTER ADAPTER CONTRACT AND VERSION
  -- ===========================================================================

  v_contract :=
    public.register_commercial_provider_adapter_contract_internal(
      v_adapter_key,
      'Migration 118 No-op Adapter',
      'payment_gateway',
      'MIGRATION_118',
      jsonb_build_object(
        'temporary', true,
        'certification', 'MIGRATION_118',
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
      'Migration 118 transactional adapter lifecycle certification',
      'MIGRATION_118',
      jsonb_build_object(
        'temporary', true,
        'network_accessed', false,
        'credentials_resolved', false
      )
    );

  -- ===========================================================================
  -- 6. DECLARE CANONICAL OPERATIONS
  -- ===========================================================================

  v_operation :=
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
      'MIGRATION_118',
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
      'MIGRATION_118',
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
      'MIGRATION_118',
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
      'MIGRATION_118',
      jsonb_build_object('processing_enabled', false)
    );

  -- ===========================================================================
  -- 7. DECLARE NORMALIZED ERROR MAPPINGS
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
      'MIGRATION_118',
      jsonb_build_object(
        'temporary', true,
        'certification', 'MIGRATION_118'
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
      'MIGRATION_118',
      jsonb_build_object(
        'temporary', true,
        'certification', 'MIGRATION_118'
      )
    );

  -- ===========================================================================
  -- 8. STRUCTURAL VALIDATION AND APPROVAL
  -- ===========================================================================

  v_validation :=
    public.validate_commercial_provider_adapter_version_internal(
      v_version.id,
      'MIGRATION_118',
      jsonb_build_object(
        'certification', 'MIGRATION_118',
        'network_accessed', false,
        'credentials_resolved', false
      )
    );

  if v_validation.validation_status <> 'passed' then
    raise exception
      'MIGRATION_118_ADAPTER_VALIDATION_FAILED status=%, failures=%, warnings=%',
      v_validation.validation_status,
      v_validation.failures,
      v_validation.warnings;
  end if;

  v_version :=
    public.approve_commercial_provider_adapter_version_internal(
      v_version.id,
      'MIGRATION_118',
      'Transactional lifecycle certification'
    );

  if v_version.version_status <> 'approved' then
    raise exception 'MIGRATION_118_ADAPTER_APPROVAL_FAILED';
  end if;

  -- ===========================================================================
  -- 9. CREATE AND EVALUATE PASSIVE BINDING
  -- ===========================================================================

  v_binding :=
    public.create_commercial_provider_adapter_binding_internal(
      v_provider.id,
      null,
      v_version.id,
      v_policy.id,
      'MIGRATION_118',
      jsonb_build_object(
        'mode', 'certification_only',
        'network_access', false,
        'credential_resolution', false
      ),
      jsonb_build_object(
        'temporary', true,
        'certification', 'MIGRATION_118'
      )
    );

  v_binding :=
    public.evaluate_commercial_provider_adapter_binding_internal(
      v_binding.id,
      'MIGRATION_118'
    );

  if v_binding.binding_status <> 'validated'
     or v_binding.readiness_status <> 'ready'
     or coalesce((v_binding.readiness_report->>'validated_without_provider_call')::boolean, false) is not true
     or coalesce((v_binding.readiness_report->>'execution_enabled')::boolean, true) is not false
     or coalesce((v_binding.readiness_report->>'network_access_enabled')::boolean, true) is not false
     or coalesce((v_binding.readiness_report->>'credential_resolution_enabled')::boolean, true) is not false then
    raise exception
      'MIGRATION_118_BINDING_READINESS_FAILED status=%, readiness=%, report=%',
      v_binding.binding_status,
      v_binding.readiness_status,
      v_binding.readiness_report;
  end if;

  -- ===========================================================================
  -- 10. GUARD CERTIFICATION
  -- ===========================================================================

  begin
    update public.commercial_provider_adapter_versions
    set change_summary = 'ILLEGAL_MUTATION'
    where id = v_version.id;

    raise exception 'MIGRATION_118_VERSION_GUARD_NOT_ENFORCED';
  exception
    when sqlstate '55000' then
      if sqlerrm = 'COMMERCIAL_PROVIDER_ADAPTER_VERSION_IMMUTABLE' then
        v_version_guard := true;
      else
        raise;
      end if;
  end;

  begin
    update public.commercial_provider_adapter_validations
    set metadata = metadata || '{"illegal":true}'::jsonb
    where id = v_validation.id;

    raise exception 'MIGRATION_118_VALIDATION_GUARD_NOT_ENFORCED';
  exception
    when sqlstate '55000' then
      if sqlerrm = 'COMMERCIAL_PROVIDER_ADAPTER_VALIDATION_APPEND_ONLY' then
        v_validation_guard := true;
      else
        raise;
      end if;
  end;

  begin
    update public.commercial_provider_adapter_events
    set reason = 'ILLEGAL_MUTATION'
    where adapter_contract_id = v_contract.id;

    raise exception 'MIGRATION_118_EVENT_GUARD_NOT_ENFORCED';
  exception
    when sqlstate '55000' then
      if sqlerrm = 'COMMERCIAL_PROVIDER_ADAPTER_EVENT_APPEND_ONLY' then
        v_event_guard := true;
      else
        raise;
      end if;
  end;

  begin
    update public.commercial_provider_adapter_policies
    set operation_timeout_ms = operation_timeout_ms + 1
    where id = v_policy.id;

    raise exception 'MIGRATION_118_POLICY_GUARD_NOT_ENFORCED';
  exception
    when sqlstate '55000' then
      if sqlerrm = 'COMMERCIAL_PROVIDER_ADAPTER_POLICY_IMMUTABLE' then
        v_policy_guard := true;
      else
        raise;
      end if;
  end;

  begin
    update public.commercial_provider_adapter_bindings
    set
      binding_status = 'active',
      activated_at = clock_timestamp(),
      activated_by = 'MIGRATION_118'
    where id = v_binding.id;

    raise exception 'MIGRATION_118_BINDING_ACTIVATION_GUARD_NOT_ENFORCED';
  exception
    when check_violation then
      v_binding_activation_guard := true;
  end;

  -- ===========================================================================
  -- 11. LIFECYCLE ASSERTIONS
  -- ===========================================================================

  select count(*) into v_contract_count
  from public.commercial_provider_adapter_contracts
  where id = v_contract.id;

  select count(*) into v_version_count
  from public.commercial_provider_adapter_versions
  where adapter_contract_id = v_contract.id;

  select count(*) into v_operation_count
  from public.commercial_provider_adapter_operations
  where adapter_version_id = v_version.id
    and operation_status = 'certified';

  select count(*) into v_error_count
  from public.commercial_provider_adapter_error_mappings
  where adapter_version_id = v_version.id
    and mapping_status = 'approved';

  select count(*) into v_validation_count
  from public.commercial_provider_adapter_validations
  where adapter_version_id = v_version.id
    and validation_status = 'passed';

  select count(*) into v_binding_count
  from public.commercial_provider_adapter_bindings
  where id = v_binding.id
    and binding_status = 'validated'
    and readiness_status = 'ready';

  select count(*) into v_event_count
  from public.commercial_provider_adapter_events
  where adapter_contract_id = v_contract.id;

  if v_contract_count <> 1
     or v_version_count <> 1
     or v_operation_count <> 4
     or v_error_count <> 2
     or v_validation_count <> 1
     or v_binding_count <> 1 then
    raise exception
      'MIGRATION_118_LIFECYCLE_ASSERTION_FAILED contracts=%, versions=%, operations=%, errors=%, validations=%, bindings=%',
      v_contract_count,
      v_version_count,
      v_operation_count,
      v_error_count,
      v_validation_count,
      v_binding_count;
  end if;

  if v_event_count <> 12 then
    raise exception
      'MIGRATION_118_EVENT_COUNT_ASSERTION_FAILED expected=12 actual=%',
      v_event_count;
  end if;

  if not (
    v_version_guard
    and v_validation_guard
    and v_event_guard
    and v_policy_guard
    and v_binding_activation_guard
  ) then
    raise exception
      'MIGRATION_118_GUARD_ASSERTION_FAILED version=%, validation=%, event=%, policy=%, binding_activation=%',
      v_version_guard,
      v_validation_guard,
      v_event_guard,
      v_policy_guard,
      v_binding_activation_guard;
  end if;

  -- ===========================================================================
  -- 12. ECONOMIC AND CHECKOUT NON-MUTATION ASSERTIONS
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
      'MIGRATION_118_NON_MUTATION_ASSERTION_FAILED purchase_delta=%, session_delta=%, request_delta=%, callback_delta=%, reconciliation_delta=%, wallet_delta=%, ledger_delta=%, outbox_delta=%',
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
    'MIGRATION_118_CERTIFIED provider_count=1, contract_count=%, version_count=%, certified_operation_count=%, approved_error_mapping_count=%, passed_validation_count=%, validated_binding_count=%, adapter_event_count=%, version_guard=%, validation_guard=%, event_guard=%, policy_guard=%, binding_activation_guard=%, adapter_execution_enabled=false, network_access_enabled=false, credential_resolution_enabled=false, callback_verification_enabled=false, purchase_delta=0, checkout_session_delta=0, provider_request_delta=0, callback_delta=0, reconciliation_delta=0, wallet_delta=0, ledger_delta=0, outbox_delta=0, policy_temporarily_approved=%, rollback_required=true',
    v_contract_count,
    v_version_count,
    v_operation_count,
    v_error_count,
    v_validation_count,
    v_binding_count,
    v_event_count,
    v_version_guard,
    v_validation_guard,
    v_event_guard,
    v_policy_guard,
    v_binding_activation_guard,
    v_policy_temporarily_approved;
end
$$;

rollback;

\echo ''
\echo 'MIGRATION_118_TRANSACTION_ROLLED_BACK'
\echo 'No provider, adapter contract, adapter version, operation, error mapping, validation, binding, event, policy approval, checkout record, purchase, wallet, ledger or outbox mutation was persisted.'
