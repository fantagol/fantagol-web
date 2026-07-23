-- =============================================================================
-- FANTAGOL
-- Migration: 121_commercial_provider_execution_gateway_lifecycle_certification.sql
-- Milestone: Commercial Platform - Provider Execution Gateway Lifecycle Certification
--
-- Purpose:
--   Transactionally certify migration 120 together with its adapter dependencies:
--     - temporary provider and passive approved adapter binding
--     - temporary approval of the default execution-gateway policy
--     - canonical command intake
--     - idempotency reservation and replay
--     - idempotency conflict guard
--     - passive policy evaluation and command hold
--     - passive lease offer
--     - blocked dispatch attempt and normalized receipt
--     - immutable / append-only / no-dispatch guards
--     - commercial and economic non-mutation assertions
--
-- Persistence model:
--   The complete certification runs inside one transaction and ends with ROLLBACK.
-- =============================================================================

\set ON_ERROR_STOP on

begin;

set local statement_timeout = '180s';
set local lock_timeout = '15s';
set local idle_in_transaction_session_timeout = '240s';

do $$
declare
  -- Adapter dependency objects.
  v_adapter_policy public.commercial_provider_adapter_policies;
  v_provider public.commercial_providers;
  v_contract public.commercial_provider_adapter_contracts;
  v_version public.commercial_provider_adapter_versions;
  v_create_operation public.commercial_provider_adapter_operations;
  v_operation public.commercial_provider_adapter_operations;
  v_error_mapping public.commercial_provider_adapter_error_mappings;
  v_validation public.commercial_provider_adapter_validations;
  v_binding public.commercial_provider_adapter_bindings;

  -- Gateway objects.
  v_gateway_policy public.commercial_provider_execution_policies;
  v_command public.commercial_provider_execution_commands;
  v_replayed_command public.commercial_provider_execution_commands;
  v_lease public.commercial_provider_execution_leases;
  v_attempt public.commercial_provider_execution_attempts;

  -- Temporary identifiers.
  v_provider_code text :=
    'MIGRATION_121_PROVIDER_' ||
    upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));

  v_adapter_key text :=
    'migration_121_noop_' ||
    lower(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));

  v_command_key text :=
    'migration_121:command:' ||
    lower(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16));

  v_idempotency_key text :=
    'migration_121:idempotency:' ||
    lower(substr(replace(gen_random_uuid()::text, '-', ''), 1, 20));

  v_request_payload jsonb :=
    jsonb_build_object(
      'operation_code', 'CREATE_CHECKOUT',
      'idempotency_key', 'temporary-certification',
      'correlation_id', gen_random_uuid(),
      'payload', jsonb_build_object(
        'purchase_id', gen_random_uuid(),
        'amount_minor', 999,
        'currency', 'EUR',
        'certification_only', true
      )
    );

  -- Non-mutation baselines.
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

  -- Lifecycle counts.
  v_command_count bigint;
  v_idempotency_count bigint;
  v_duplicate_count bigint;
  v_lease_count bigint;
  v_attempt_count bigint;
  v_receipt_count bigint;
  v_gateway_event_count bigint;
  v_adapter_event_count bigint;

  -- Guards.
  v_idempotency_conflict_guard boolean := false;
  v_gateway_policy_guard boolean := false;
  v_receipt_guard boolean := false;
  v_gateway_event_guard boolean := false;
  v_claimed_lease_guard boolean := false;
  v_dispatch_state_guard boolean := false;
  v_network_attempt_guard boolean := false;

  v_adapter_policy_temporarily_approved boolean := false;
  v_gateway_policy_temporarily_approved boolean := false;
begin
  -- ===========================================================================
  -- 1. DEPENDENCY ASSERTIONS
  -- ===========================================================================

  if to_regclass('public.commercial_provider_execution_policies') is null
     or to_regclass('public.commercial_provider_execution_commands') is null
     or to_regclass('public.commercial_provider_execution_idempotency') is null
     or to_regclass('public.commercial_provider_execution_rate_windows') is null
     or to_regclass('public.commercial_provider_execution_leases') is null
     or to_regclass('public.commercial_provider_execution_attempts') is null
     or to_regclass('public.commercial_provider_execution_receipts') is null
     or to_regclass('public.commercial_provider_execution_events') is null then
    raise exception 'MIGRATION_121_REQUIRES_MIGRATION_120';
  end if;

  if to_regclass('public.commercial_provider_adapter_policies') is null
     or to_regclass('public.commercial_provider_adapter_contracts') is null
     or to_regclass('public.commercial_provider_adapter_versions') is null
     or to_regclass('public.commercial_provider_adapter_operations') is null
     or to_regclass('public.commercial_provider_adapter_error_mappings') is null
     or to_regclass('public.commercial_provider_adapter_bindings') is null
     or to_regclass('public.commercial_provider_adapter_validations') is null
     or to_regclass('public.commercial_provider_adapter_events') is null then
    raise exception 'MIGRATION_121_REQUIRES_MIGRATIONS_117_119';
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
      approved_by = 'MIGRATION_121',
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
    raise exception 'MIGRATION_121_UNSAFE_ADAPTER_POLICY';
  end if;

  -- ===========================================================================
  -- 4. TEMPORARILY APPROVE PASSIVE GATEWAY POLICY
  -- ===========================================================================

  select *
  into strict v_gateway_policy
  from public.commercial_provider_execution_policies
  where policy_code = 'DEFAULT_PROVIDER_EXECUTION_GATEWAY'
    and environment = 'test'
  order by version_number desc
  limit 1;

  if v_gateway_policy.policy_status <> 'approved' then
    update public.commercial_provider_execution_policies
    set
      policy_status = 'approved',
      approved_by = 'MIGRATION_121',
      approved_at = clock_timestamp()
    where id = v_gateway_policy.id
    returning * into v_gateway_policy;

    v_gateway_policy_temporarily_approved := true;
  end if;

  if v_gateway_policy.command_intake_enabled is not true
     or v_gateway_policy.policy_evaluation_enabled is not true
     or v_gateway_policy.idempotency_enforcement_enabled is not true
     or v_gateway_policy.lease_governance_enabled is not true
     or v_gateway_policy.rate_limit_governance_enabled is not true
     or v_gateway_policy.automatic_dispatch_enabled
     or v_gateway_policy.adapter_execution_enabled
     or v_gateway_policy.network_access_enabled
     or v_gateway_policy.credential_resolution_enabled then
    raise exception 'MIGRATION_121_UNSAFE_GATEWAY_POLICY';
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
    'Migration 121 Temporary Provider',
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
      'certification', 'MIGRATION_121'
    ),
    1
  )
  returning * into v_provider;

  raise notice
    'MIGRATION_121_TEMPORARY_PROVIDER_CREATED provider_id=%, provider_code=%, adapter_key=%',
    v_provider.id,
    v_provider.provider_code,
    v_provider.adapter_key;

  -- ===========================================================================
  -- 6. REGISTER ADAPTER CONTRACT AND VERSION
  -- ===========================================================================

  v_contract :=
    public.register_commercial_provider_adapter_contract_internal(
      v_adapter_key,
      'Migration 121 No-op Gateway Adapter',
      'payment_gateway',
      'MIGRATION_121',
      jsonb_build_object(
        'temporary', true,
        'certification', 'MIGRATION_121',
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
      'Migration 121 execution gateway lifecycle certification',
      'MIGRATION_121',
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
      'MIGRATION_121',
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
      'MIGRATION_121',
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
      'MIGRATION_121',
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
      'MIGRATION_121',
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
      'MIGRATION_121',
      jsonb_build_object(
        'temporary', true,
        'certification', 'MIGRATION_121'
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
      'MIGRATION_121',
      jsonb_build_object(
        'temporary', true,
        'certification', 'MIGRATION_121'
      )
    );

  v_validation :=
    public.validate_commercial_provider_adapter_version_internal(
      v_version.id,
      'MIGRATION_121',
      jsonb_build_object(
        'certification', 'MIGRATION_121',
        'network_accessed', false,
        'credentials_resolved', false
      )
    );

  if v_validation.validation_status <> 'passed' then
    raise exception
      'MIGRATION_121_ADAPTER_VALIDATION_FAILED status=%, failures=%, warnings=%',
      v_validation.validation_status,
      v_validation.failures,
      v_validation.warnings;
  end if;

  v_version :=
    public.approve_commercial_provider_adapter_version_internal(
      v_version.id,
      'MIGRATION_121',
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
      'MIGRATION_121',
      jsonb_build_object(
        'mode', 'certification_only',
        'network_access', false,
        'credential_resolution', false
      ),
      jsonb_build_object(
        'temporary', true,
        'certification', 'MIGRATION_121'
      )
    );

  v_binding :=
    public.evaluate_commercial_provider_adapter_binding_internal(
      v_binding.id,
      'MIGRATION_121'
    );

  if v_binding.binding_status <> 'validated'
     or v_binding.readiness_status <> 'ready'
     or coalesce((v_binding.readiness_report->>'validated_without_provider_call')::boolean, false) is not true
     or coalesce((v_binding.readiness_report->>'execution_enabled')::boolean, true) is not false
     or coalesce((v_binding.readiness_report->>'network_access_enabled')::boolean, true) is not false
     or coalesce((v_binding.readiness_report->>'credential_resolution_enabled')::boolean, true) is not false then
    raise exception
      'MIGRATION_121_BINDING_READINESS_FAILED status=%, readiness=%, report=%',
      v_binding.binding_status,
      v_binding.readiness_status,
      v_binding.readiness_report;
  end if;

  -- ===========================================================================
  -- 10. ENQUEUE CANONICAL COMMAND
  -- ===========================================================================

  v_command :=
    public.enqueue_commercial_provider_execution_command_internal(
      v_command_key,
      v_idempotency_key,
      v_provider.id,
      v_binding.id,
      v_create_operation.id,
      v_gateway_policy.id,
      'create_checkout',
      v_request_payload,
      'MIGRATION_121',
      null,
      null,
      100::smallint,
      gen_random_uuid(),
      null,
      jsonb_build_object(
        'temporary', true,
        'certification', 'MIGRATION_121',
        'external_dispatch', false
      )
    );

  if v_command.command_status <> 'received'
     or v_command.checkout_session_id is not null
     or v_command.checkout_provider_request_id is not null then
    raise exception
      'MIGRATION_121_COMMAND_INTAKE_FAILED status=%, checkout_session_id=%, provider_request_id=%',
      v_command.command_status,
      v_command.checkout_session_id,
      v_command.checkout_provider_request_id;
  end if;

  -- ===========================================================================
  -- 11. IDEMPOTENCY REPLAY
  -- ===========================================================================

  v_replayed_command :=
    public.enqueue_commercial_provider_execution_command_internal(
      v_command_key,
      v_idempotency_key,
      v_provider.id,
      v_binding.id,
      v_create_operation.id,
      v_gateway_policy.id,
      'create_checkout',
      v_request_payload,
      'MIGRATION_121_REPLAY',
      null,
      null,
      100::smallint,
      gen_random_uuid(),
      null,
      jsonb_build_object(
        'temporary', true,
        'certification', 'MIGRATION_121',
        'replay', true
      )
    );

  if v_replayed_command.id <> v_command.id then
    raise exception
      'MIGRATION_121_IDEMPOTENCY_REPLAY_CREATED_NEW_COMMAND original=%, replay=%',
      v_command.id,
      v_replayed_command.id;
  end if;

  select duplicate_count
  into strict v_duplicate_count
  from public.commercial_provider_execution_idempotency
  where command_id = v_command.id;

  if v_duplicate_count <> 1 then
    raise exception
      'MIGRATION_121_IDEMPOTENCY_REPLAY_COUNT_FAILED expected=1 actual=%',
      v_duplicate_count;
  end if;

  -- ===========================================================================
  -- 12. IDEMPOTENCY CONFLICT GUARD
  -- ===========================================================================

  begin
    perform public.enqueue_commercial_provider_execution_command_internal(
      v_command_key,
      v_idempotency_key,
      v_provider.id,
      v_binding.id,
      v_create_operation.id,
      v_gateway_policy.id,
      'create_checkout',
      v_request_payload ||
        jsonb_build_object(
          'payload',
          (v_request_payload->'payload') ||
          jsonb_build_object('amount_minor', 1000)
        ),
      'MIGRATION_121_CONFLICT',
      null,
      null,
      100::smallint,
      gen_random_uuid(),
      null,
      jsonb_build_object(
        'temporary', true,
        'certification', 'MIGRATION_121',
        'conflict_probe', true
      )
    );

    raise exception 'MIGRATION_121_IDEMPOTENCY_CONFLICT_GUARD_NOT_ENFORCED';
  exception
    when others then
      if sqlerrm = 'COMMERCIAL_PROVIDER_EXECUTION_IDEMPOTENCY_CONFLICT' then
        v_idempotency_conflict_guard := true;
      else
        raise;
      end if;
  end;

  -- ===========================================================================
  -- 13. POLICY EVALUATION: COMMAND MUST BE HELD
  -- ===========================================================================

  v_command :=
    public.evaluate_commercial_provider_execution_command_internal(
      v_command.id,
      'MIGRATION_121'
    );

  if v_command.command_status <> 'held'
     or v_command.evaluated_at is null
     or v_command.held_at is null
     or v_command.terminal_reason <> 'FOUNDATION_EXECUTION_DISABLED' then
    raise exception
      'MIGRATION_121_POLICY_HOLD_FAILED status=%, evaluated_at=%, held_at=%, reason=%',
      v_command.command_status,
      v_command.evaluated_at,
      v_command.held_at,
      v_command.terminal_reason;
  end if;

  -- ===========================================================================
  -- 14. PASSIVE LEASE AND BLOCKED ATTEMPT
  -- ===========================================================================

  v_lease :=
    public.offer_commercial_provider_execution_lease_internal(
      v_command.id,
      'MIGRATION_121'
    );

  if v_lease.lease_status <> 'offered'
     or v_lease.claimed_at is not null
     or v_lease.worker_key is not null then
    raise exception
      'MIGRATION_121_PASSIVE_LEASE_FAILED status=%, claimed_at=%, worker=%',
      v_lease.lease_status,
      v_lease.claimed_at,
      v_lease.worker_key;
  end if;

  v_attempt :=
    public.record_blocked_commercial_provider_execution_attempt_internal(
      v_command.id,
      v_lease.id,
      'MIGRATION_121',
      'FOUNDATION_EXECUTION_DISABLED'
    );

  if v_attempt.attempt_status <> 'blocked'
     or v_attempt.adapter_execution_requested
     or v_attempt.credentials_resolved
     or v_attempt.network_requested
     or v_attempt.network_performed
     or v_attempt.started_at is not null then
    raise exception
      'MIGRATION_121_BLOCKED_ATTEMPT_FAILED status=%, adapter=%, credentials=%, network_requested=%, network_performed=%, started_at=%',
      v_attempt.attempt_status,
      v_attempt.adapter_execution_requested,
      v_attempt.credentials_resolved,
      v_attempt.network_requested,
      v_attempt.network_performed,
      v_attempt.started_at;
  end if;

  -- ===========================================================================
  -- 15. IMMUTABILITY AND APPEND-ONLY GUARDS
  -- ===========================================================================

  begin
    update public.commercial_provider_execution_policies
    set maximum_attempts = maximum_attempts + 1
    where id = v_gateway_policy.id;

    raise exception 'MIGRATION_121_GATEWAY_POLICY_GUARD_NOT_ENFORCED';
  exception
    when sqlstate '55000' then
      if sqlerrm = 'COMMERCIAL_PROVIDER_EXECUTION_POLICY_IMMUTABLE' then
        v_gateway_policy_guard := true;
      else
        raise;
      end if;
  end;

  begin
    update public.commercial_provider_execution_receipts
    set metadata = metadata || '{"illegal":true}'::jsonb
    where command_id = v_command.id;

    raise exception 'MIGRATION_121_RECEIPT_GUARD_NOT_ENFORCED';
  exception
    when sqlstate '55000' then
      if sqlerrm = 'COMMERCIAL_PROVIDER_EXECUTION_RECEIPT_APPEND_ONLY' then
        v_receipt_guard := true;
      else
        raise;
      end if;
  end;

  begin
    update public.commercial_provider_execution_events
    set reason = 'ILLEGAL_MUTATION'
    where command_id = v_command.id;

    raise exception 'MIGRATION_121_GATEWAY_EVENT_GUARD_NOT_ENFORCED';
  exception
    when sqlstate '55000' then
      if sqlerrm = 'COMMERCIAL_PROVIDER_EXECUTION_EVENT_APPEND_ONLY' then
        v_gateway_event_guard := true;
      else
        raise;
      end if;
  end;

  -- ===========================================================================
  -- 16. CLAIM / DISPATCH / NETWORK STRUCTURAL GUARDS
  -- ===========================================================================

  begin
    update public.commercial_provider_execution_leases
    set
      lease_status = 'claimed',
      claimed_at = clock_timestamp(),
      worker_key = 'migration_121_worker'
    where id = v_lease.id;

    raise exception 'MIGRATION_121_CLAIMED_LEASE_GUARD_NOT_ENFORCED';
  exception
    when check_violation then
      v_claimed_lease_guard := true;
  end;

  begin
    update public.commercial_provider_execution_commands
    set command_status = 'dispatching'
    where id = v_command.id;

    raise exception 'MIGRATION_121_DISPATCH_STATE_GUARD_NOT_ENFORCED';
  exception
    when check_violation then
      v_dispatch_state_guard := true;
  end;

  begin
    update public.commercial_provider_execution_attempts
    set
      attempt_status = 'started',
      adapter_execution_requested = true,
      credentials_resolved = true,
      network_requested = true,
      network_performed = true,
      started_at = clock_timestamp()
    where id = v_attempt.id;

    raise exception 'MIGRATION_121_NETWORK_ATTEMPT_GUARD_NOT_ENFORCED';
  exception
    when check_violation then
      v_network_attempt_guard := true;
  end;

  -- ===========================================================================
  -- 17. LIFECYCLE COUNT ASSERTIONS
  -- ===========================================================================

  select count(*) into v_command_count
  from public.commercial_provider_execution_commands
  where id = v_command.id;

  select count(*) into v_idempotency_count
  from public.commercial_provider_execution_idempotency
  where command_id = v_command.id
    and registry_status = 'reserved'
    and duplicate_count = 1;

  select count(*) into v_lease_count
  from public.commercial_provider_execution_leases
  where command_id = v_command.id
    and lease_status = 'offered';

  select count(*) into v_attempt_count
  from public.commercial_provider_execution_attempts
  where command_id = v_command.id
    and attempt_status = 'blocked'
    and adapter_execution_requested = false
    and credentials_resolved = false
    and network_requested = false
    and network_performed = false;

  select count(*) into v_receipt_count
  from public.commercial_provider_execution_receipts
  where command_id = v_command.id;

  select count(*) into v_gateway_event_count
  from public.commercial_provider_execution_events
  where command_id = v_command.id;

  select count(*) into v_adapter_event_count
  from public.commercial_provider_adapter_events
  where adapter_contract_id = v_contract.id;

  if v_command_count <> 1
     or v_idempotency_count <> 1
     or v_lease_count <> 1
     or v_attempt_count <> 1
     or v_receipt_count <> 2
     or v_gateway_event_count <> 4
     or v_adapter_event_count <> 12 then
    raise exception
      'MIGRATION_121_LIFECYCLE_COUNT_ASSERTION_FAILED command=%, idempotency=%, lease=%, attempt=%, receipt=%, gateway_events=%, adapter_events=%',
      v_command_count,
      v_idempotency_count,
      v_lease_count,
      v_attempt_count,
      v_receipt_count,
      v_gateway_event_count,
      v_adapter_event_count;
  end if;

  if not (
    v_idempotency_conflict_guard
    and v_gateway_policy_guard
    and v_receipt_guard
    and v_gateway_event_guard
    and v_claimed_lease_guard
    and v_dispatch_state_guard
    and v_network_attempt_guard
  ) then
    raise exception
      'MIGRATION_121_GUARD_ASSERTION_FAILED idempotency_conflict=%, policy=%, receipt=%, event=%, claimed_lease=%, dispatch_state=%, network_attempt=%',
      v_idempotency_conflict_guard,
      v_gateway_policy_guard,
      v_receipt_guard,
      v_gateway_event_guard,
      v_claimed_lease_guard,
      v_dispatch_state_guard,
      v_network_attempt_guard;
  end if;

  -- ===========================================================================
  -- 18. READ MODEL ASSERTION
  -- ===========================================================================

  if coalesce(
    (
      public.get_commercial_provider_execution_command_internal(v_command.id)
      -> 'command'
      ->> 'command_status'
    ),
    ''
  ) <> 'held' then
    raise exception 'MIGRATION_121_READ_MODEL_ASSERTION_FAILED';
  end if;

  -- ===========================================================================
  -- 19. ECONOMIC AND CHECKOUT NON-MUTATION ASSERTIONS
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
      'MIGRATION_121_NON_MUTATION_ASSERTION_FAILED purchase_delta=%, session_delta=%, request_delta=%, callback_delta=%, reconciliation_delta=%, wallet_delta=%, ledger_delta=%, outbox_delta=%',
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
  -- 20. FINAL CERTIFICATION NOTICE
  -- ===========================================================================

  raise notice
    'MIGRATION_121_CERTIFIED provider_count=1, adapter_contract_count=1, adapter_version_count=1, certified_operation_count=4, validated_binding_count=1, adapter_event_count=%, command_count=%, idempotency_count=%, idempotency_duplicate_count=%, lease_count=%, blocked_attempt_count=%, receipt_count=%, gateway_event_count=%, command_status=held, idempotency_conflict_guard=%, gateway_policy_guard=%, receipt_guard=%, gateway_event_guard=%, claimed_lease_guard=%, dispatch_state_guard=%, network_attempt_guard=%, automatic_dispatch_enabled=false, adapter_execution_enabled=false, network_access_enabled=false, credential_resolution_enabled=false, purchase_delta=0, checkout_session_delta=0, provider_request_delta=0, callback_delta=0, reconciliation_delta=0, wallet_delta=0, ledger_delta=0, outbox_delta=0, adapter_policy_temporarily_approved=%, gateway_policy_temporarily_approved=%, rollback_required=true',
    v_adapter_event_count,
    v_command_count,
    v_idempotency_count,
    v_duplicate_count,
    v_lease_count,
    v_attempt_count,
    v_receipt_count,
    v_gateway_event_count,
    v_idempotency_conflict_guard,
    v_gateway_policy_guard,
    v_receipt_guard,
    v_gateway_event_guard,
    v_claimed_lease_guard,
    v_dispatch_state_guard,
    v_network_attempt_guard,
    v_adapter_policy_temporarily_approved,
    v_gateway_policy_temporarily_approved;
end
$$;

rollback;

\echo ''
\echo 'MIGRATION_121_TRANSACTION_ROLLED_BACK'
\echo 'No provider, adapter, gateway command, idempotency record, lease, attempt, receipt, event, policy approval, checkout record, purchase, wallet, ledger or outbox mutation was persisted.'
