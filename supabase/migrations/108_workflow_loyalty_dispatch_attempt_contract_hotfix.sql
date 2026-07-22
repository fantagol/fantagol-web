-- ============================================================================
-- FANTAGOL
-- Migration: 108_workflow_loyalty_dispatch_attempt_contract_hotfix.sql
-- Milestone: Commercial Platform — Workflow Loyalty Dispatch Contract Hotfix
--
-- Purpose:
--   - Correct the attempt-history mutation contract introduced by Migration 107
--   - Preserve immutable attempt identity and forbid deletion
--   - Allow exactly one controlled transition from "started" to a terminal
--     or scheduled outcome
--   - Keep the dispatcher, retry reconciler and lease recovery executable
--
-- Safety:
--   - No loyalty binding, producer, policy, campaign or reward source enabled
--   - No runtime event inserted
--   - No game-table or Workflow Engine trigger introduced
-- ============================================================================

begin;

-- ============================================================================
-- 0. DEPENDENCY ASSERTIONS
-- ============================================================================

do $$
begin
  if to_regclass('public.workflow_loyalty_dispatch_attempts') is null
     or to_regclass('public.workflow_loyalty_dispatch_outbox') is null
     or to_regclass('public.workflow_loyalty_producer_bindings') is null then
    raise exception using
      errcode = 'P0001',
      message = 'MIGRATION_108_REQUIRES_MIGRATION_107';
  end if;

  if to_regprocedure(
    'public.process_workflow_loyalty_dispatch_internal(uuid,text,uuid)'
  ) is null
     or to_regprocedure(
       'public.reconcile_expired_workflow_loyalty_leases_internal(integer)'
     ) is null then
    raise exception using
      errcode = 'P0001',
      message = 'MIGRATION_108_REQUIRES_WORKFLOW_LOYALTY_DISPATCH_RUNTIME';
  end if;
end;
$$;

-- ============================================================================
-- 1. REPLACE THE OVER-RESTRICTIVE APPEND-ONLY TRIGGER
-- ============================================================================

drop trigger if exists workflow_loyalty_attempts_append_only
  on public.workflow_loyalty_dispatch_attempts;

drop function if exists public.protect_workflow_loyalty_dispatch_attempts();

create or replace function public.enforce_workflow_loyalty_attempt_contract()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    raise exception using
      errcode = '55000',
      message = 'WORKFLOW_LOYALTY_DISPATCH_ATTEMPT_DELETE_FORBIDDEN';
  end if;

  -- Attempt identity is immutable for the lifetime of the record.
  if new.id is distinct from old.id
     or new.outbox_event_id is distinct from old.outbox_event_id
     or new.attempt_number is distinct from old.attempt_number
     or new.worker_id is distinct from old.worker_id
     or new.lease_token is distinct from old.lease_token
     or new.started_at is distinct from old.started_at
     or new.created_at is distinct from old.created_at then
    raise exception using
      errcode = '55000',
      message = 'WORKFLOW_LOYALTY_DISPATCH_ATTEMPT_IDENTITY_IMMUTABLE';
  end if;

  -- Once completed, an attempt becomes fully immutable.
  if old.completed_at is not null then
    raise exception using
      errcode = '55000',
      message = 'WORKFLOW_LOYALTY_DISPATCH_ATTEMPT_ALREADY_COMPLETED';
  end if;

  -- The only mutable source state is "started".
  if old.attempt_status <> 'started' then
    raise exception using
      errcode = '55000',
      message = 'WORKFLOW_LOYALTY_DISPATCH_ATTEMPT_SOURCE_STATE_INVALID';
  end if;

  -- A started attempt must transition exactly once to an allowed outcome.
  if new.attempt_status not in (
    'dispatched',
    'duplicate',
    'rejected',
    'retry_scheduled',
    'dead_letter',
    'lease_lost'
  ) then
    raise exception using
      errcode = '55000',
      message = 'WORKFLOW_LOYALTY_DISPATCH_ATTEMPT_TRANSITION_INVALID';
  end if;

  if new.completed_at is null then
    raise exception using
      errcode = '23514',
      message = 'WORKFLOW_LOYALTY_DISPATCH_ATTEMPT_COMPLETED_AT_REQUIRED';
  end if;

  if new.completed_at < old.started_at then
    raise exception using
      errcode = '23514',
      message = 'WORKFLOW_LOYALTY_DISPATCH_ATTEMPT_COMPLETION_TIME_INVALID';
  end if;

  -- Successful outcomes must carry the authoritative downstream references.
  if new.attempt_status in ('dispatched', 'duplicate')
     and (
       new.producer_receipt_id is null
       or new.runtime_inbox_event_id is null
     ) then
    raise exception using
      errcode = '23514',
      message = 'WORKFLOW_LOYALTY_DISPATCH_ATTEMPT_DELIVERY_REFERENCES_REQUIRED';
  end if;

  -- Non-delivery outcomes cannot claim a successful delivery.
  if new.attempt_status in (
       'rejected',
       'retry_scheduled',
       'dead_letter',
       'lease_lost'
     )
     and (
       new.producer_receipt_id is not null
       or new.runtime_inbox_event_id is not null
     ) then
    raise exception using
      errcode = '23514',
      message = 'WORKFLOW_LOYALTY_DISPATCH_ATTEMPT_DELIVERY_REFERENCES_FORBIDDEN';
  end if;

  -- Error-bearing outcomes require an explicit error contract.
  if new.attempt_status in (
       'rejected',
       'retry_scheduled',
       'dead_letter',
       'lease_lost'
     )
     and (
       nullif(trim(new.error_code), '') is null
       or nullif(trim(new.error_message), '') is null
     ) then
    raise exception using
      errcode = '23514',
      message = 'WORKFLOW_LOYALTY_DISPATCH_ATTEMPT_ERROR_REQUIRED';
  end if;

  if jsonb_typeof(coalesce(new.response_payload, '{}'::jsonb)) <> 'object' then
    raise exception using
      errcode = '23514',
      message = 'WORKFLOW_LOYALTY_DISPATCH_ATTEMPT_RESPONSE_INVALID';
  end if;

  return new;
end;
$$;

create trigger workflow_loyalty_attempts_contract
before update or delete
on public.workflow_loyalty_dispatch_attempts
for each row
execute function public.enforce_workflow_loyalty_attempt_contract();

comment on function public.enforce_workflow_loyalty_attempt_contract() is
  'Preserves immutable attempt identity, forbids deletion and permits one controlled started-to-outcome transition.';

-- ============================================================================
-- 2. STRENGTHEN TABLE-LEVEL COMPLETION CONTRACT
-- ============================================================================

alter table public.workflow_loyalty_dispatch_attempts
  drop constraint if exists workflow_loyalty_attempts_completion_check;

alter table public.workflow_loyalty_dispatch_attempts
  add constraint workflow_loyalty_attempts_completion_check
  check (
    (
      attempt_status = 'started'
      and completed_at is null
    )
    or
    (
      attempt_status in (
        'dispatched',
        'duplicate',
        'rejected',
        'retry_scheduled',
        'dead_letter',
        'lease_lost'
      )
      and completed_at is not null
    )
  );

alter table public.workflow_loyalty_dispatch_attempts
  drop constraint if exists workflow_loyalty_attempts_delivery_reference_check;

alter table public.workflow_loyalty_dispatch_attempts
  add constraint workflow_loyalty_attempts_delivery_reference_check
  check (
    (
      attempt_status in ('dispatched', 'duplicate')
      and producer_receipt_id is not null
      and runtime_inbox_event_id is not null
    )
    or
    (
      attempt_status not in ('dispatched', 'duplicate')
      and producer_receipt_id is null
      and runtime_inbox_event_id is null
    )
  );

alter table public.workflow_loyalty_dispatch_attempts
  drop constraint if exists workflow_loyalty_attempts_error_contract_check;

alter table public.workflow_loyalty_dispatch_attempts
  add constraint workflow_loyalty_attempts_error_contract_check
  check (
    (
      attempt_status in (
        'rejected',
        'retry_scheduled',
        'dead_letter',
        'lease_lost'
      )
      and nullif(trim(error_code), '') is not null
      and nullif(trim(error_message), '') is not null
    )
    or
    (
      attempt_status not in (
        'rejected',
        'retry_scheduled',
        'dead_letter',
        'lease_lost'
      )
    )
  );

-- ============================================================================
-- 3. SECURITY
-- ============================================================================

revoke all on function public.enforce_workflow_loyalty_attempt_contract()
  from public, anon, authenticated;

grant execute on function public.enforce_workflow_loyalty_attempt_contract()
  to service_role;

-- ============================================================================
-- 4. FINAL ASSERTIONS
-- ============================================================================

do $$
declare
  v_trigger_count integer;
  v_old_trigger_count integer;
  v_contract_constraint_count integer;
  v_binding_count integer;
  v_enabled_binding_count integer;
  v_enabled_producer_count integer;
  v_enabled_policy_count integer;
  v_enabled_campaign_count integer;
  v_enabled_source_count integer;
  v_outbox_count integer;
  v_attempt_count integer;
begin
  select count(*)
  into v_trigger_count
  from pg_trigger t
  join pg_class c
    on c.oid = t.tgrelid
  join pg_namespace n
    on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relname = 'workflow_loyalty_dispatch_attempts'
    and t.tgname = 'workflow_loyalty_attempts_contract'
    and not t.tgisinternal;

  if v_trigger_count <> 1 then
    raise exception using
      errcode = 'P0001',
      message = 'WORKFLOW_LOYALTY_ATTEMPT_CONTRACT_TRIGGER_MISSING';
  end if;

  select count(*)
  into v_old_trigger_count
  from pg_trigger t
  join pg_class c
    on c.oid = t.tgrelid
  join pg_namespace n
    on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relname = 'workflow_loyalty_dispatch_attempts'
    and t.tgname = 'workflow_loyalty_attempts_append_only'
    and not t.tgisinternal;

  if v_old_trigger_count <> 0 then
    raise exception using
      errcode = 'P0001',
      message = 'WORKFLOW_LOYALTY_OLD_APPEND_ONLY_TRIGGER_STILL_PRESENT';
  end if;

  select count(*)
  into v_contract_constraint_count
  from pg_constraint con
  join pg_class c
    on c.oid = con.conrelid
  join pg_namespace n
    on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relname = 'workflow_loyalty_dispatch_attempts'
    and con.conname in (
      'workflow_loyalty_attempts_completion_check',
      'workflow_loyalty_attempts_delivery_reference_check',
      'workflow_loyalty_attempts_error_contract_check'
    );

  if v_contract_constraint_count <> 3 then
    raise exception using
      errcode = 'P0001',
      message = 'WORKFLOW_LOYALTY_ATTEMPT_CONSTRAINTS_INCOMPLETE';
  end if;

  if to_regprocedure(
    'public.enforce_workflow_loyalty_attempt_contract()'
  ) is null then
    raise exception using
      errcode = 'P0001',
      message = 'WORKFLOW_LOYALTY_ATTEMPT_CONTRACT_FUNCTION_MISSING';
  end if;

  select count(*)
  into v_binding_count
  from public.workflow_loyalty_producer_bindings;

  select count(*)
  into v_enabled_binding_count
  from public.workflow_loyalty_producer_bindings
  where enabled = true;

  select count(*)
  into v_enabled_producer_count
  from public.loyalty_event_producers
  where enabled = true;

  select count(*)
  into v_enabled_policy_count
  from public.loyalty_reward_policies
  where enabled = true;

  select count(*)
  into v_enabled_campaign_count
  from public.reward_campaigns
  where campaign_code like 'LOYALTY_%'
    and enabled = true;

  select count(*)
  into v_enabled_source_count
  from public.reward_sources
  where source_code = 'INTERNAL_ACHIEVEMENT'
    and enabled = true;

  select count(*)
  into v_outbox_count
  from public.workflow_loyalty_dispatch_outbox;

  select count(*)
  into v_attempt_count
  from public.workflow_loyalty_dispatch_attempts;

  if v_binding_count <> 10
     or v_enabled_binding_count <> 0
     or v_enabled_producer_count <> 0
     or v_enabled_policy_count <> 0
     or v_enabled_campaign_count <> 0
     or v_enabled_source_count <> 0 then
    raise exception using
      errcode = 'P0001',
      message = 'WORKFLOW_LOYALTY_HOTFIX_SAFETY_STATE_INVALID';
  end if;

  if v_outbox_count <> 0 or v_attempt_count <> 0 then
    raise exception using
      errcode = 'P0001',
      message = 'WORKFLOW_LOYALTY_HOTFIX_RUNTIME_MUST_REMAIN_EMPTY';
  end if;

  raise notice 'WORKFLOW LOYALTY DISPATCH ATTEMPT CONTRACT HOTFIX CERTIFIED';
  raise notice 'Attempt deletion remains forbidden';
  raise notice 'Attempt identity fields are immutable';
  raise notice 'One controlled started-to-outcome transition is now permitted';
  raise notice 'Dispatcher and lease reconciliation completion updates are unblocked';
  raise notice 'Successful delivery references and error outcomes are constrained';
  raise notice 'No binding, producer, policy, campaign or reward source enabled';
  raise notice 'Runtime outbox and attempt history remain empty';
  raise notice 'Controlled E2E certification remains pending';
end;
$$;

commit;
