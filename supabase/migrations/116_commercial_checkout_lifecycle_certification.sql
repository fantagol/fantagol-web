-- ============================================================================
-- FANTAGOL
-- Migration: 116_commercial_checkout_lifecycle_certification.sql
-- Purpose:
--   Transactional certification of migration 115 checkout orchestration.
--
-- Safety:
--   - Creates only transaction-local certification data
--   - Performs no provider call
--   - Performs no purchase confirmation or refund
--   - Performs no ledger or wallet mutation
--   - Ends with ROLLBACK
-- ============================================================================

begin;

set local statement_timeout = '120s';
set local lock_timeout = '15s';
set local idle_in_transaction_session_timeout = '120s';

do $$
declare
  v_wallet public.commercial_wallets;
  v_product public.commercial_products;
  v_provider public.commercial_providers;
  v_payment_provider public.payment_providers;
  v_purchase public.commercial_purchases;
  v_purchase_policy public.commercial_purchase_runtime_policies;
  v_checkout_policy public.commercial_checkout_orchestration_policies;
  v_authorization public.commercial_purchase_authorizations;
  v_session public.commercial_checkout_sessions;
  v_request public.commercial_checkout_provider_requests;
  v_callback public.commercial_checkout_callbacks;
  v_reconciliation public.commercial_checkout_reconciliation_observations;

  v_test_user_id uuid;
  v_wallet_created boolean := false;
  v_provider_created boolean := false;
  v_purchase_policy_was_approved boolean := false;
  v_checkout_policy_was_approved boolean := false;
  v_payment_provider_was_enabled boolean := false;

  v_wallet_before jsonb;
  v_wallet_after jsonb;
  v_ledger_before bigint;
  v_ledger_after bigint;
  v_outbox_before bigint;
  v_outbox_after bigint;

  v_event_guard boolean := false;
  v_policy_guard boolean := false;
  v_request_guard boolean := false;
  v_callback_guard boolean := false;
  v_session_guard boolean := false;

  v_purchase_event_count bigint;
  v_checkout_event_count bigint;
begin
  if to_regclass('public.commercial_checkout_orchestration_policies') is null
     or to_regclass('public.commercial_checkout_sessions') is null
     or to_regclass('public.commercial_checkout_provider_requests') is null
     or to_regclass('public.commercial_checkout_callbacks') is null
     or to_regclass('public.commercial_checkout_reconciliation_observations') is null
     or to_regclass('public.commercial_checkout_orchestration_events') is null then
    raise exception 'MIGRATION_116_REQUIRES_MIGRATION_115';
  end if;

  select *
  into v_wallet
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
      raise exception 'MIGRATION_116_REQUIRES_EXISTING_AUTH_USER';
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
      'MIGRATION_116_TEMPORARY_WALLET_CREATED wallet_id=%, user_id=%',
      v_wallet.id,
      v_wallet.user_id;
  end if;

  select *
  into v_product
  from public.commercial_products
  where product_code = 'STARTER'
  order by created_at, id
  limit 1;

  if not found then
    raise exception 'MIGRATION_116_REQUIRES_STARTER_PRODUCT';
  end if;

  select *
  into v_provider
  from public.commercial_providers
  order by
    case when provider_code = 'STRIPE' then 0 else 1 end,
    created_at,
    id
  limit 1;

  if not found then
    insert into public.commercial_providers (
      provider_code,
      display_name,
      legal_name,
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
      'MIGRATION_116_TEST_PROVIDER',
      'Migration 116 Test Provider',
      null,
      'payment_gateway',
      'external',
      'adapter',
      'migration_116_noop_adapter',
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
        'certification', 'MIGRATION_116'
      ),
      1
    )
    returning * into v_provider;

    v_provider_created := true;

    raise notice
      'MIGRATION_116_TEMPORARY_PROVIDER_CREATED provider_id=%, provider_code=%',
      v_provider.id,
      v_provider.provider_code;
  end if;

  select *
  into v_payment_provider
  from public.payment_providers
  where provider_code = 'stripe'
  order by created_at, id
  limit 1;

  if not found then
    raise exception 'MIGRATION_116_REQUIRES_STRIPE_PAYMENT_PROVIDER';
  end if;

  select *
  into v_purchase_policy
  from public.commercial_purchase_runtime_policies
  where policy_code = 'DEFAULT_ONE_TIME_PURCHASE'
    and environment = 'test'
  order by version_number desc
  limit 1;

  if not found then
    raise exception 'MIGRATION_116_REQUIRES_PURCHASE_RUNTIME_POLICY';
  end if;

  select *
  into v_checkout_policy
  from public.commercial_checkout_orchestration_policies
  where policy_code = 'DEFAULT_PROVIDER_CHECKOUT'
  order by version desc
  limit 1;

  if not found then
    raise exception 'MIGRATION_116_REQUIRES_CHECKOUT_POLICY';
  end if;

  v_wallet_before := to_jsonb(v_wallet);

  select count(*)
  into v_ledger_before
  from public.commercial_ledger
  where wallet_id = v_wallet.id;

  select count(*)
  into v_outbox_before
  from public.commercial_purchase_runtime_outbox;

  if v_purchase_policy.policy_status <> 'approved' then
    update public.commercial_purchase_runtime_policies
    set
      policy_status = 'approved',
      approved_at = now(),
      approved_by = 'MIGRATION_116'
    where id = v_purchase_policy.id;

    v_purchase_policy_was_approved := true;

    select *
    into v_purchase_policy
    from public.commercial_purchase_runtime_policies
    where id = v_purchase_policy.id;
  end if;

  if v_checkout_policy.policy_status <> 'approved' then
    update public.commercial_checkout_orchestration_policies
    set
      policy_status = 'approved',
      approved_at = now(),
      approved_by = 'MIGRATION_116'
    where id = v_checkout_policy.id;

    v_checkout_policy_was_approved := true;

    select *
    into v_checkout_policy
    from public.commercial_checkout_orchestration_policies
    where id = v_checkout_policy.id;
  end if;

  if coalesce(v_payment_provider.enabled, false) = false then
    update public.payment_providers
    set enabled = true
    where id = v_payment_provider.id
    returning * into v_payment_provider;

    v_payment_provider_was_enabled := true;
  end if;

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
    v_payment_provider.id,
    v_payment_provider.provider_code,
    'pending',
    'pending',
    v_product.passes,
    v_product.price_minor,
    v_product.currency,
    'migration-116-' || replace(gen_random_uuid()::text, '-', ''),
    gen_random_uuid(),
    jsonb_build_object(
      'certification', 'MIGRATION_116',
      'commercial_provider_id', v_provider.id,
      'external_provider_call_allowed', false,
      'rollback_required', true
    )
  )
  returning * into v_purchase;

  declare
    v_readiness jsonb;
    v_request_result jsonb;
    v_decision_result jsonb;
  begin
    v_readiness :=
      public.evaluate_commercial_purchase_runtime_readiness_internal(
        v_purchase.id
      );

    if coalesce((v_readiness->>'evaluated')::boolean, false) is not true
       or v_readiness->>'runtime_state' <> 'ready'
       or v_readiness->>'readiness_status' <> 'ready' then
      raise exception
        'MIGRATION_116_READINESS_ASSERTION_FAILED payload=%',
        v_readiness;
    end if;

    v_request_result :=
      public.request_commercial_purchase_authorization_internal(
        v_purchase.id,
        'attach_checkout',
        'migration-116-auth-' || replace(gen_random_uuid()::text, '-', ''),
        'MIGRATION_116',
        jsonb_build_object('certification', true)
      );

    if coalesce((v_request_result->>'requested')::boolean, false) is not true then
      raise exception
        'MIGRATION_116_AUTHORIZATION_REQUEST_FAILED payload=%',
        v_request_result;
    end if;

    select *
    into strict v_authorization
    from public.commercial_purchase_authorizations
    where id = (v_request_result->>'authorization_id')::uuid;

    v_decision_result :=
      public.decide_commercial_purchase_authorization_internal(
        v_authorization.id,
        'approved',
        'MIGRATION_116',
        'Transactional lifecycle certification'
      );

    if coalesce((v_decision_result->>'decided')::boolean, false) is not true
       or v_decision_result->>'authorization_status' <> 'approved' then
      raise exception
        'MIGRATION_116_AUTHORIZATION_DECISION_FAILED payload=%',
        v_decision_result;
    end if;

    select *
    into strict v_authorization
    from public.commercial_purchase_authorizations
    where id = v_authorization.id;
  end;

  v_session :=
    public.create_commercial_checkout_session_internal(
      v_purchase.id,
      v_provider.id,
      v_checkout_policy.id,
      v_authorization.id,
      'MIGRATION_116_SESSION_' || replace(gen_random_uuid()::text, '-', ''),
      v_purchase.price_minor,
      v_purchase.currency,
      now() + interval '30 minutes',
      'https://example.invalid/return',
      'https://example.invalid/cancel',
      'MIGRATION_116',
      jsonb_build_object('certification', true)
    );

  v_request :=
    public.record_commercial_checkout_provider_request_internal(
      v_session.id,
      'create_checkout',
      'MIGRATION_116_REQUEST_' || replace(gen_random_uuid()::text, '-', ''),
      null,
      'MIGRATION_116',
      jsonb_build_object(
        'amount_minor', v_purchase.price_minor,
        'currency', v_purchase.currency
      )
    );

  v_callback :=
    public.record_commercial_checkout_callback_internal(
      v_provider.id,
      'MIGRATION_116_EVENT_' || replace(gen_random_uuid()::text, '-', ''),
      'checkout_completed',
      v_session.id,
      v_purchase.id,
      null,
      'MIGRATION_116',
      jsonb_build_object(
        'simulated', true,
        'payment_status', 'succeeded'
      ),
      jsonb_build_object(
        'signature', 'not-verified-certification'
      )
    );

  v_reconciliation :=
    public.record_commercial_checkout_reconciliation_internal(
      v_purchase.id,
      v_provider.id,
      'MIGRATION_116_RECON_' || replace(gen_random_uuid()::text, '-', ''),
      v_session.id,
      v_callback.id,
      v_purchase.purchase_status,
      v_session.session_status,
      'succeeded',
      null,
      'provider_ahead',
      'manual_review',
      'MIGRATION_116',
      jsonb_build_object(
        'simulated', true,
        'economic_mutation_performed', false
      ),
      'Provider state intentionally ahead of local state for certification'
    );

  begin
    update public.commercial_checkout_orchestration_events
    set reason = 'ILLEGAL UPDATE'
    where purchase_id = v_purchase.id;
  exception
    when others then
      if sqlerrm like '%COMMERCIAL_CHECKOUT_EVENT_APPEND_ONLY%' then
        v_event_guard := true;
      else
        raise;
      end if;
  end;

  begin
    update public.commercial_checkout_orchestration_policies
    set session_ttl_seconds = session_ttl_seconds + 1
    where id = v_checkout_policy.id;
  exception
    when others then
      if sqlerrm like '%COMMERCIAL_CHECKOUT_POLICY_IMMUTABLE_AFTER_APPROVAL%' then
        v_policy_guard := true;
      else
        raise;
      end if;
  end;

  begin
    update public.commercial_checkout_provider_requests
    set request_status = 'dispatched',
        dispatched_at = now()
    where id = v_request.id;
  exception
    when check_violation then
      v_request_guard := true;
  end;

  begin
    update public.commercial_checkout_callbacks
    set callback_status = 'processed',
        processed_at = now()
    where id = v_callback.id;
  exception
    when check_violation then
      v_callback_guard := true;
  end;

  begin
    update public.commercial_checkout_sessions
    set session_status = 'completed',
        completed_at = now()
    where id = v_session.id;
  exception
    when check_violation then
      v_session_guard := true;
  end;

  select to_jsonb(w)
  into v_wallet_after
  from public.commercial_wallets w
  where w.id = v_wallet.id;

  select count(*)
  into v_ledger_after
  from public.commercial_ledger
  where wallet_id = v_wallet.id;

  select count(*)
  into v_outbox_after
  from public.commercial_purchase_runtime_outbox;

  select count(*)
  into v_purchase_event_count
  from public.commercial_purchase_runtime_events
  where purchase_id = v_purchase.id;

  select count(*)
  into v_checkout_event_count
  from public.commercial_checkout_orchestration_events
  where purchase_id = v_purchase.id;

  if v_session.session_status <> 'authorized' then
    raise exception 'MIGRATION_116_SESSION_STATUS_ASSERTION_FAILED status=%',
      v_session.session_status;
  end if;

  if v_request.request_status <> 'recorded' then
    raise exception 'MIGRATION_116_REQUEST_STATUS_ASSERTION_FAILED status=%',
      v_request.request_status;
  end if;

  if v_callback.callback_status <> 'received'
     or v_callback.signature_status <> 'not_evaluated' then
    raise exception
      'MIGRATION_116_CALLBACK_STATUS_ASSERTION_FAILED status=%, signature=%',
      v_callback.callback_status,
      v_callback.signature_status;
  end if;

  if v_reconciliation.observation_status <> 'observed'
     or v_reconciliation.recommended_action <> 'manual_review' then
    raise exception
      'MIGRATION_116_RECONCILIATION_ASSERTION_FAILED status=%, action=%',
      v_reconciliation.observation_status,
      v_reconciliation.recommended_action;
  end if;

  if v_wallet_before is distinct from v_wallet_after then
    raise exception 'MIGRATION_116_WALLET_MUTATION_DETECTED';
  end if;

  if v_ledger_after <> v_ledger_before then
    raise exception
      'MIGRATION_116_LEDGER_MUTATION_DETECTED before=%, after=%',
      v_ledger_before,
      v_ledger_after;
  end if;

  if v_outbox_after <> v_outbox_before then
    raise exception
      'MIGRATION_116_OUTBOX_MUTATION_DETECTED before=%, after=%',
      v_outbox_before,
      v_outbox_after;
  end if;

  if not (
    v_event_guard
    and v_policy_guard
    and v_request_guard
    and v_callback_guard
    and v_session_guard
  ) then
    raise exception
      'MIGRATION_116_GUARD_ASSERTION_FAILED event=%, policy=%, request=%, callback=%, session=%',
      v_event_guard,
      v_policy_guard,
      v_request_guard,
      v_callback_guard,
      v_session_guard;
  end if;

  if v_checkout_event_count <> 4 then
    raise exception
      'MIGRATION_116_CHECKOUT_EVENT_COUNT_ASSERTION_FAILED count=%',
      v_checkout_event_count;
  end if;

  raise notice
    'MIGRATION_116_CERTIFIED purchase_count=1, authorization_count=1, session_count=1, provider_request_count=1, callback_count=1, reconciliation_count=1, checkout_event_count=%, purchase_event_count=%, request_guard=%, callback_guard=%, session_guard=%, event_guard=%, policy_guard=%, ledger_delta=0, wallet_delta=0, outbox_delta=0, temporary_wallet_created=%, temporary_provider_created=%, purchase_policy_temporarily_approved=%, checkout_policy_temporarily_approved=%, payment_provider_temporarily_enabled=%, rollback_required=true',
    v_checkout_event_count,
    v_purchase_event_count,
    v_request_guard,
    v_callback_guard,
    v_session_guard,
    v_event_guard,
    v_policy_guard,
    v_wallet_created,
    v_provider_created,
    v_purchase_policy_was_approved,
    v_checkout_policy_was_approved,
    v_payment_provider_was_enabled;
end
$$;

rollback;

\echo ''
\echo 'MIGRATION_116_TRANSACTION_ROLLED_BACK'
\echo 'No purchase, authorization, checkout session, provider request, callback, reconciliation observation, event, wallet, provider, ledger mutation, outbox mutation, provider enablement or policy approval was persisted.'
