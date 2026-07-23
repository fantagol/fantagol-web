-- =============================================================================
-- FANTAGOL
-- Migration 114: Commercial Purchase Runtime Lifecycle Certification
-- Classification: TRANSACTIONAL CERTIFICATION / NON-PERSISTENT
--
-- Purpose:
--   Certify the lifecycle introduced by migration 113 without invoking any
--   external provider and without mutating the economic source of truth.
--
-- Safety:
--   - Runs inside one transaction
--   - Reuses an existing commercial wallet when available
--   - Otherwise creates a transaction-local zero-balance wallet for an existing auth user
--   - Temporarily approves the test runtime policy
--   - Temporarily enables the seeded Stripe test provider
--   - Creates one temporary pending purchase
--   - Evaluates readiness, requests and approves authorization
--   - Creates one PLANNED execution attempt only
--   - Creates no outbox row
--   - Calls no provider adapter
--   - Writes no commercial ledger entry
--   - Changes no commercial wallet balance/statistic
--   - Verifies append-only and policy immutability guards
--   - Ends with ROLLBACK
-- =============================================================================

\set ON_ERROR_STOP on

begin;

set local statement_timeout = '120s';
set local lock_timeout = '15s';
set local idle_in_transaction_session_timeout = '180s';

DO $certification$
declare
  v_wallet public.commercial_wallets;
  v_test_user_id uuid;
  v_wallet_created boolean := false;
  v_product public.commercial_products;
  v_provider public.payment_providers;
  v_policy public.commercial_purchase_runtime_policies;
  v_purchase public.commercial_purchases;
  v_authorization public.commercial_purchase_authorizations;
  v_attempt public.commercial_purchase_execution_attempts;
  v_runtime public.commercial_purchase_runtime_states;

  v_correlation_id uuid := gen_random_uuid();
  v_readiness jsonb;
  v_request jsonb;
  v_decision jsonb;

  v_ledger_count_before bigint;
  v_ledger_count_after bigint;
  v_wallet_available_before bigint;
  v_wallet_available_after bigint;
  v_wallet_lifetime_purchased_before bigint;
  v_wallet_lifetime_purchased_after bigint;
  v_outbox_count bigint;
  v_purchase_event_count bigint;

  v_event_guard_verified boolean := false;
  v_policy_guard_verified boolean := false;
begin
  -- ---------------------------------------------------------------------------
  -- 1. Dependency assertions
  -- ---------------------------------------------------------------------------
  if to_regclass('public.commercial_purchases') is null
     or to_regclass('public.commercial_wallets') is null
     or to_regclass('public.commercial_ledger') is null
     or to_regclass('public.commercial_purchase_runtime_policies') is null
     or to_regclass('public.commercial_purchase_authorizations') is null
     or to_regclass('public.commercial_purchase_execution_attempts') is null
     or to_regclass('public.commercial_purchase_runtime_states') is null
     or to_regclass('public.commercial_purchase_runtime_outbox') is null
     or to_regclass('public.commercial_purchase_runtime_events') is null then
    raise exception 'MIGRATION_114_DEPENDENCY_MISSING';
  end if;

  select * into v_wallet
  from public.commercial_wallets
  order by created_at, id
  limit 1;

  if not found then
    select id
    into v_test_user_id
    from auth.users
    order by created_at, id
    limit 1;

    if v_test_user_id is null then
      raise exception 'MIGRATION_114_REQUIRES_EXISTING_AUTH_USER';
    end if;

    insert into public.commercial_wallets (
      user_id,
      status,
      available_passes,
      lifetime_earned,
      lifetime_consumed,
      lifetime_purchased,
      lifetime_rewarded,
      lifetime_promotional,
      ledger_version
    ) values (
      v_test_user_id,
      'active',
      0,
      0,
      0,
      0,
      0,
      0,
      0
    )
    returning * into v_wallet;

    v_wallet_created := true;

    raise notice
      'MIGRATION_114_TEMPORARY_WALLET_CREATED wallet_id=%, user_id=%',
      v_wallet.id,
      v_wallet.user_id;
  end if;

  select * into v_product
  from public.commercial_products
  where product_code = 'STARTER';

  if not found then
    raise exception 'MIGRATION_114_STARTER_PRODUCT_NOT_FOUND';
  end if;

  if not exists (
    select 1
    from public.commercial_product_pass_components c
    where c.product_id = v_product.id
      and c.component_status = 'certified'
      and c.quantity = v_product.passes
  ) then
    raise exception 'MIGRATION_114_STARTER_COMPONENT_NOT_CERTIFIED';
  end if;

  select * into v_provider
  from public.payment_providers
  where provider_code = 'stripe';

  if not found then
    raise exception 'MIGRATION_114_STRIPE_PROVIDER_NOT_FOUND';
  end if;

  select * into v_policy
  from public.commercial_purchase_runtime_policies
  where policy_code = 'DEFAULT_ONE_TIME_PURCHASE'
    and environment = 'test'
  order by version_number desc
  limit 1;

  if not found then
    raise exception 'MIGRATION_114_TEST_POLICY_NOT_FOUND';
  end if;

  if v_policy.policy_status <> 'draft' then
    raise exception 'MIGRATION_114_EXPECTED_DRAFT_TEST_POLICY status=%', v_policy.policy_status;
  end if;

  -- ---------------------------------------------------------------------------
  -- 2. Economic baseline
  -- ---------------------------------------------------------------------------
  select count(*) into v_ledger_count_before
  from public.commercial_ledger;

  v_wallet_available_before := v_wallet.available_passes;
  v_wallet_lifetime_purchased_before := v_wallet.lifetime_purchased;

  -- ---------------------------------------------------------------------------
  -- 3. Transaction-local readiness prerequisites
  -- ---------------------------------------------------------------------------
  update public.commercial_purchase_runtime_policies
  set
    policy_status = 'approved',
    approved_by = 'MIGRATION_114_CERTIFICATION',
    approved_at = clock_timestamp()
  where id = v_policy.id
  returning * into v_policy;

  update public.payment_providers
  set enabled = true
  where id = v_provider.id
  returning * into v_provider;

  -- ---------------------------------------------------------------------------
  -- 4. Temporary pending purchase
  -- ---------------------------------------------------------------------------
  insert into public.commercial_purchases (
    user_id,
    wallet_id,
    product_id,
    product_code,
    provider_id,
    provider_code,
    purchase_status,
    payment_status,
    passes_awarded,
    price_minor,
    currency,
    client_idempotency_key,
    correlation_id,
    metadata
  ) values (
    v_wallet.user_id,
    v_wallet.id,
    v_product.id,
    v_product.product_code,
    v_provider.id,
    v_provider.provider_code,
    'pending',
    'pending',
    v_product.passes,
    v_product.price_minor,
    v_product.currency,
    'migration-114-' || replace(gen_random_uuid()::text, '-', ''),
    v_correlation_id,
    jsonb_build_object(
      'certification', 'MIGRATION_114',
      'external_provider_call_allowed', false,
      'rollback_required', true
    )
  ) returning * into v_purchase;

  -- ---------------------------------------------------------------------------
  -- 5. Readiness must become READY but automatic execution must remain false
  -- ---------------------------------------------------------------------------
  v_readiness := public.evaluate_commercial_purchase_runtime_readiness_internal(
    v_purchase.id
  );

  if coalesce((v_readiness->>'evaluated')::boolean, false) is not true
     or v_readiness->>'runtime_state' <> 'ready'
     or v_readiness->>'readiness_status' <> 'ready'
     or coalesce((v_readiness->>'automatic_execution_allowed')::boolean, true) is not false then
    raise exception 'MIGRATION_114_READINESS_CERTIFICATION_FAILED payload=%', v_readiness;
  end if;

  select * into strict v_runtime
  from public.commercial_purchase_runtime_states
  where purchase_id = v_purchase.id;

  if v_runtime.runtime_state <> 'ready'
     or v_runtime.readiness_status <> 'ready'
     or v_runtime.current_action <> 'attach_checkout'
     or v_runtime.automatic_execution_allowed then
    raise exception 'MIGRATION_114_RUNTIME_READY_PROJECTION_INVALID';
  end if;

  -- ---------------------------------------------------------------------------
  -- 6. Explicit authorization request and approval
  -- ---------------------------------------------------------------------------
  v_request := public.request_commercial_purchase_authorization_internal(
    v_purchase.id,
    'attach_checkout',
    'migration-114-auth-' || replace(gen_random_uuid()::text, '-', ''),
    'MIGRATION_114_CERTIFICATION',
    jsonb_build_object('provider_dispatch_allowed', false)
  );

  if coalesce((v_request->>'requested')::boolean, false) is not true then
    raise exception 'MIGRATION_114_AUTHORIZATION_REQUEST_FAILED payload=%', v_request;
  end if;

  select * into strict v_authorization
  from public.commercial_purchase_authorizations
  where id = (v_request->>'authorization_id')::uuid;

  v_decision := public.decide_commercial_purchase_authorization_internal(
    v_authorization.id,
    'approved',
    'MIGRATION_114_CERTIFICATION',
    'Transactional lifecycle certification only; no dispatch permitted.'
  );

  if coalesce((v_decision->>'decided')::boolean, false) is not true
     or v_decision->>'authorization_status' <> 'approved'
     or coalesce((v_decision->>'automatic_execution_scheduled')::boolean, true) is not false then
    raise exception 'MIGRATION_114_AUTHORIZATION_DECISION_FAILED payload=%', v_decision;
  end if;

  select * into strict v_authorization
  from public.commercial_purchase_authorizations
  where id = v_authorization.id;

  if v_authorization.authorization_status <> 'approved' then
    raise exception 'MIGRATION_114_AUTHORIZATION_PROJECTION_INVALID';
  end if;

  -- ---------------------------------------------------------------------------
  -- 7. Planned attempt only: no lease, execution, provider call or outbox
  -- ---------------------------------------------------------------------------
  insert into public.commercial_purchase_execution_attempts (
    purchase_id,
    authorization_id,
    provider_id,
    attempt_number,
    execution_action,
    execution_status,
    idempotency_key,
    correlation_id,
    request_snapshot,
    response_snapshot,
    metadata
  ) values (
    v_purchase.id,
    v_authorization.id,
    v_provider.id,
    1,
    'attach_checkout',
    'planned',
    'migration-114-attempt-' || replace(gen_random_uuid()::text, '-', ''),
    v_correlation_id,
    jsonb_build_object(
      'simulation', true,
      'provider_call', false
    ),
    '{}'::jsonb,
    jsonb_build_object(
      'certification', 'MIGRATION_114',
      'dispatch_forbidden', true
    )
  ) returning * into v_attempt;

  perform public.append_commercial_purchase_runtime_event_internal(
    'PURCHASE_EXECUTION_ATTEMPT_PLANNED',
    'MIGRATION_114_CERTIFICATION',
    v_correlation_id,
    v_purchase.id,
    v_policy.id,
    v_authorization.id,
    v_attempt.id,
    'authorized',
    'authorized',
    'Attempt recorded for audit only; execution deliberately not started.',
    null,
    jsonb_build_object(
      'execution_action', v_attempt.execution_action,
      'execution_status', v_attempt.execution_status,
      'provider_call_performed', false
    )
  );

  update public.commercial_purchase_runtime_states
  set
    runtime_state = 'authorized',
    readiness_status = 'ready',
    current_action = 'attach_checkout',
    active_authorization_id = v_authorization.id,
    last_attempt_id = v_attempt.id,
    automatic_execution_allowed = false,
    state_reason = 'MIGRATION_114_AUTHORIZED_NO_DISPATCH',
    metadata = metadata || jsonb_build_object(
      'certification', 'MIGRATION_114',
      'dispatch_forbidden', true
    )
  where purchase_id = v_purchase.id
  returning * into v_runtime;

  if v_runtime.runtime_state <> 'authorized'
     or v_runtime.active_authorization_id <> v_authorization.id
     or v_runtime.last_attempt_id <> v_attempt.id
     or v_runtime.automatic_execution_allowed then
    raise exception 'MIGRATION_114_AUTHORIZED_RUNTIME_PROJECTION_INVALID';
  end if;

  -- ---------------------------------------------------------------------------
  -- 8. Foundation must not create a dispatchable outbox message
  -- ---------------------------------------------------------------------------
  select count(*) into v_outbox_count
  from public.commercial_purchase_runtime_outbox
  where purchase_id = v_purchase.id;

  if v_outbox_count <> 0 then
    raise exception 'MIGRATION_114_OUTBOX_MUST_REMAIN_EMPTY count=%', v_outbox_count;
  end if;

  -- ---------------------------------------------------------------------------
  -- 9. Append-only lifecycle guard certification
  -- ---------------------------------------------------------------------------
  begin
    update public.commercial_purchase_runtime_events
    set reason = 'FORBIDDEN_MUTATION'
    where purchase_id = v_purchase.id;

    raise exception 'MIGRATION_114_EVENT_GUARD_DID_NOT_BLOCK_UPDATE';
  exception
    when others then
      if sqlerrm = 'MIGRATION_114_EVENT_GUARD_DID_NOT_BLOCK_UPDATE' then
        raise;
      end if;

      if position('COMMERCIAL_PURCHASE_RUNTIME_EVENT_APPEND_ONLY' in sqlerrm) = 0 then
        raise exception 'MIGRATION_114_EVENT_GUARD_UNEXPECTED_ERROR: %', sqlerrm;
      end if;

      v_event_guard_verified := true;
  end;

  -- ---------------------------------------------------------------------------
  -- 10. Approved policy immutability guard certification
  -- ---------------------------------------------------------------------------
  begin
    update public.commercial_purchase_runtime_policies
    set authorization_ttl_seconds = authorization_ttl_seconds + 1
    where id = v_policy.id;

    raise exception 'MIGRATION_114_POLICY_GUARD_DID_NOT_BLOCK_UPDATE';
  exception
    when others then
      if sqlerrm = 'MIGRATION_114_POLICY_GUARD_DID_NOT_BLOCK_UPDATE' then
        raise;
      end if;

      if position('COMMERCIAL_PURCHASE_RUNTIME_POLICY_IMMUTABLE' in sqlerrm) = 0 then
        raise exception 'MIGRATION_114_POLICY_GUARD_UNEXPECTED_ERROR: %', sqlerrm;
      end if;

      v_policy_guard_verified := true;
  end;

  -- ---------------------------------------------------------------------------
  -- 11. Timeline assertions
  -- ---------------------------------------------------------------------------
  select count(*) into v_purchase_event_count
  from public.commercial_purchase_runtime_events
  where purchase_id = v_purchase.id;

  if v_purchase_event_count <> 4 then
    raise exception 'MIGRATION_114_TIMELINE_EVENT_COUNT_INVALID expected=4 actual=%',
      v_purchase_event_count;
  end if;

  if not exists (
    select 1 from public.commercial_purchase_runtime_events
    where purchase_id = v_purchase.id
      and event_type = 'PURCHASE_RUNTIME_READINESS_EVALUATED'
  ) or not exists (
    select 1 from public.commercial_purchase_runtime_events
    where purchase_id = v_purchase.id
      and event_type = 'PURCHASE_AUTHORIZATION_REQUESTED'
  ) or not exists (
    select 1 from public.commercial_purchase_runtime_events
    where purchase_id = v_purchase.id
      and event_type = 'PURCHASE_AUTHORIZATION_APPROVED'
  ) or not exists (
    select 1 from public.commercial_purchase_runtime_events
    where purchase_id = v_purchase.id
      and event_type = 'PURCHASE_EXECUTION_ATTEMPT_PLANNED'
  ) then
    raise exception 'MIGRATION_114_TIMELINE_VOCABULARY_INVALID';
  end if;

  -- ---------------------------------------------------------------------------
  -- 12. Economic invariants
  -- ---------------------------------------------------------------------------
  select count(*) into v_ledger_count_after
  from public.commercial_ledger;

  select available_passes, lifetime_purchased
  into v_wallet_available_after, v_wallet_lifetime_purchased_after
  from public.commercial_wallets
  where id = v_wallet.id;

  if v_ledger_count_after <> v_ledger_count_before then
    raise exception 'MIGRATION_114_LEDGER_MUTATION_DETECTED before=% after=%',
      v_ledger_count_before, v_ledger_count_after;
  end if;

  if v_wallet_available_after <> v_wallet_available_before
     or v_wallet_lifetime_purchased_after <> v_wallet_lifetime_purchased_before then
    raise exception 'MIGRATION_114_WALLET_MUTATION_DETECTED';
  end if;

  if exists (
    select 1
    from public.commercial_ledger l
    where l.correlation_id = v_correlation_id
  ) then
    raise exception 'MIGRATION_114_CORRELATED_LEDGER_ENTRY_DETECTED';
  end if;

  if not v_event_guard_verified or not v_policy_guard_verified then
    raise exception 'MIGRATION_114_GUARD_CERTIFICATION_INCOMPLETE';
  end if;

  raise notice
    'MIGRATION_114_CERTIFIED purchase_count=1, runtime_count=1, authorization_count=1, approved_authorization_count=1, attempt_count=1, planned_attempt_count=1, purchase_event_count=4, outbox_count=0, ledger_delta=0, wallet_delta=0, event_guard=true, policy_guard=true, temporary_wallet_created=%, rollback_required=true',
    v_wallet_created;
end;
$certification$;

rollback;

\echo ''
\echo 'MIGRATION_114_TRANSACTION_ROLLED_BACK'
\echo 'No purchase, authorization, attempt, runtime state, outbox row, ledger row, wallet, provider enablement or policy approval was persisted.'
