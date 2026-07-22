-- ============================================================================
-- FANTAGOL
-- Migration: 105_loyalty_reward_runtime_integration.sql
-- Milestone: Commercial Platform — Loyalty Reward Runtime Integration
-- Purpose:
--   - Certified event inbox between domain workflows and Loyalty Reward Policy
--   - Idempotent enqueue and dispatch
--   - Lease, retry, reconciliation and dead-letter handling
--   - Backend-only producer adapters for the ten approved loyalty event types
--   - No automatic campaign activation
--   - No frontend reward creation
-- ============================================================================

begin;

-- ============================================================================
-- 0. DEPENDENCY ASSERTIONS
-- ============================================================================

do $$
begin
  if to_regclass('public.loyalty_reward_policies') is null
     or to_regclass('public.loyalty_reward_events') is null
     or to_regclass('public.reward_revelations') is null then
    raise exception using
      errcode = 'P0001',
      message = 'MIGRATION_105_REQUIRES_MIGRATION_104';
  end if;

  if to_regprocedure(
    'public.award_loyalty_reward_internal(uuid,text,text,text,timestamp with time zone,uuid,uuid,uuid,uuid,uuid,uuid,jsonb,jsonb)'
  ) is null then
    raise exception using
      errcode = 'P0001',
      message = 'MIGRATION_105_REQUIRES_AWARD_LOYALTY_REWARD_INTERNAL';
  end if;

  if to_regprocedure(
    'public.commercial_append_event_internal(text,text,uuid,uuid,uuid,uuid,jsonb)'
  ) is null then
    raise exception using
      errcode = 'P0001',
      message = 'MIGRATION_105_REQUIRES_COMMERCIAL_EVENT_STORE';
  end if;
end;
$$;

-- ============================================================================
-- 1. CERTIFIED LOYALTY RUNTIME INBOX
-- ============================================================================

create table if not exists public.loyalty_reward_runtime_inbox (
  id uuid primary key default gen_random_uuid(),

  event_code text not null,
  event_key text not null,
  certification_reference text not null,

  user_id uuid not null,
  league_id uuid null,
  league_round_id uuid null,
  season_id uuid null,
  prediction_result_id uuid null,

  event_status text not null default 'pending',

  correlation_id uuid not null default gen_random_uuid(),
  causation_id uuid null,

  occurred_at timestamptz not null,
  received_at timestamptz not null default clock_timestamp(),
  available_at timestamptz not null default clock_timestamp(),

  attempt_count integer not null default 0,
  max_attempts integer not null default 8,

  lease_owner text null,
  leased_at timestamptz null,
  lease_expires_at timestamptz null,

  processing_started_at timestamptz null,
  processed_at timestamptz null,
  failed_at timestamptz null,
  dead_lettered_at timestamptz null,

  loyalty_reward_event_id uuid null,

  last_error_code text null,
  last_error_message text null,

  payload jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  version integer not null default 1,

  constraint loyalty_reward_runtime_inbox_event_key_key
    unique (event_key),

  constraint loyalty_reward_runtime_inbox_reward_event_key
    unique (loyalty_reward_event_id),

  constraint loyalty_reward_runtime_inbox_user_id_fkey
    foreign key (user_id)
    references auth.users (id)
    on delete restrict,

  constraint loyalty_reward_runtime_inbox_reward_event_id_fkey
    foreign key (loyalty_reward_event_id)
    references public.loyalty_reward_events (id)
    on delete restrict,

  constraint loyalty_reward_runtime_inbox_event_code_check
    check (
      event_code in (
        'LEAGUE_REACHED_8_ACTIVE_MEMBERS',
        'LEAGUE_FIRST_ROUND_CERTIFIED',
        'LEAGUE_SEASON_CERTIFIED_COMPLETE',
        'PROFILE_COMPLETED_AFTER_FIRST_LEAGUE_ROUND',
        'CERTIFIED_EXACT_ACHIEVED',
        'CERTIFIED_GRAND_SLAM_ACHIEVED',
        'CERTIFIED_CANTONATA_ACHIEVED',
        'COMPLETE_PREDICTIONS_STREAK_5_CERTIFIED',
        'COMPLETE_PREDICTIONS_STREAK_10_CERTIFIED',
        'COMPLETE_PREDICTIONS_FULL_SEASON_CERTIFIED'
      )
    ),

  constraint loyalty_reward_runtime_inbox_event_key_check
    check (length(trim(event_key)) between 8 and 300),

  constraint loyalty_reward_runtime_inbox_certification_reference_check
    check (length(trim(certification_reference)) between 8 and 500),

  constraint loyalty_reward_runtime_inbox_status_check
    check (
      event_status in (
        'pending',
        'leased',
        'processing',
        'rewarded',
        'skipped',
        'retry_scheduled',
        'failed',
        'dead_letter'
      )
    ),

  constraint loyalty_reward_runtime_inbox_attempt_count_check
    check (attempt_count >= 0),

  constraint loyalty_reward_runtime_inbox_max_attempts_check
    check (max_attempts between 1 and 100),

  constraint loyalty_reward_runtime_inbox_lease_check
    check (
      (
        lease_owner is null
        and leased_at is null
        and lease_expires_at is null
      )
      or
      (
        lease_owner is not null
        and length(trim(lease_owner)) between 3 and 200
        and leased_at is not null
        and lease_expires_at is not null
        and lease_expires_at > leased_at
      )
    ),

  constraint loyalty_reward_runtime_inbox_error_code_check
    check (
      last_error_code is null
      or length(trim(last_error_code)) between 2 and 200
    ),

  constraint loyalty_reward_runtime_inbox_error_message_check
    check (
      last_error_message is null
      or length(last_error_message) <= 2000
    ),

  constraint loyalty_reward_runtime_inbox_payload_object_check
    check (jsonb_typeof(payload) = 'object'),

  constraint loyalty_reward_runtime_inbox_metadata_object_check
    check (jsonb_typeof(metadata) = 'object'),

  constraint loyalty_reward_runtime_inbox_version_check
    check (version > 0),

  constraint loyalty_reward_runtime_inbox_terminal_state_check
    check (
      (
        event_status = 'rewarded'
        and processed_at is not null
        and loyalty_reward_event_id is not null
      )
      or event_status <> 'rewarded'
    ),

  constraint loyalty_reward_runtime_inbox_dead_letter_check
    check (
      (
        event_status = 'dead_letter'
        and dead_lettered_at is not null
      )
      or event_status <> 'dead_letter'
    )
);

create index if not exists loyalty_reward_runtime_inbox_dispatch_idx
  on public.loyalty_reward_runtime_inbox (
    event_status,
    available_at,
    received_at
  );

create index if not exists loyalty_reward_runtime_inbox_user_idx
  on public.loyalty_reward_runtime_inbox (
    user_id,
    created_at desc
  );

create index if not exists loyalty_reward_runtime_inbox_correlation_idx
  on public.loyalty_reward_runtime_inbox (correlation_id);

create index if not exists loyalty_reward_runtime_inbox_scope_idx
  on public.loyalty_reward_runtime_inbox (
    league_id,
    league_round_id,
    season_id,
    prediction_result_id
  );

create index if not exists loyalty_reward_runtime_inbox_lease_idx
  on public.loyalty_reward_runtime_inbox (
    lease_expires_at
  )
  where event_status in ('leased', 'processing');

comment on table public.loyalty_reward_runtime_inbox is
  'Certified backend-only inbox connecting domain workflows to the Loyalty Reward Policy Foundation.';

-- ============================================================================
-- 2. RUNTIME ATTEMPT LOG
-- ============================================================================

create table if not exists public.loyalty_reward_runtime_attempts (
  id uuid primary key default gen_random_uuid(),
  inbox_event_id uuid not null,
  attempt_number integer not null,
  worker_id text not null,
  attempt_status text not null,
  started_at timestamptz not null default clock_timestamp(),
  completed_at timestamptz null,
  error_code text null,
  error_message text null,
  award_result jsonb not null default '{}'::jsonb,
  correlation_id uuid not null,
  causation_id uuid null,
  created_at timestamptz not null default clock_timestamp(),

  constraint loyalty_reward_runtime_attempts_inbox_event_id_fkey
    foreign key (inbox_event_id)
    references public.loyalty_reward_runtime_inbox (id)
    on delete cascade,

  constraint loyalty_reward_runtime_attempts_event_attempt_key
    unique (inbox_event_id, attempt_number),

  constraint loyalty_reward_runtime_attempts_attempt_number_check
    check (attempt_number > 0),

  constraint loyalty_reward_runtime_attempts_worker_id_check
    check (length(trim(worker_id)) between 3 and 200),

  constraint loyalty_reward_runtime_attempts_status_check
    check (
      attempt_status in (
        'processing',
        'rewarded',
        'skipped',
        'retry_scheduled',
        'failed',
        'dead_letter'
      )
    ),

  constraint loyalty_reward_runtime_attempts_error_code_check
    check (
      error_code is null
      or length(trim(error_code)) between 2 and 200
    ),

  constraint loyalty_reward_runtime_attempts_error_message_check
    check (
      error_message is null
      or length(error_message) <= 2000
    ),

  constraint loyalty_reward_runtime_attempts_award_result_check
    check (jsonb_typeof(award_result) = 'object')
);

create index if not exists loyalty_reward_runtime_attempts_event_idx
  on public.loyalty_reward_runtime_attempts (
    inbox_event_id,
    attempt_number desc
  );

create index if not exists loyalty_reward_runtime_attempts_status_idx
  on public.loyalty_reward_runtime_attempts (
    attempt_status,
    created_at desc
  );

comment on table public.loyalty_reward_runtime_attempts is
  'Append-only execution history for each loyalty reward inbox event.';

-- ============================================================================
-- 3. UPDATED_AT TRIGGER
-- ============================================================================

create or replace function public.set_loyalty_reward_runtime_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at := clock_timestamp();
  new.version := old.version + 1;
  return new;
end;
$$;

drop trigger if exists loyalty_reward_runtime_inbox_set_updated_at
  on public.loyalty_reward_runtime_inbox;

create trigger loyalty_reward_runtime_inbox_set_updated_at
before update on public.loyalty_reward_runtime_inbox
for each row
execute function public.set_loyalty_reward_runtime_updated_at();

-- ============================================================================
-- 4. BACKEND-ONLY CERTIFIED EVENT ENQUEUE
-- ============================================================================

create or replace function public.enqueue_loyalty_certified_event_internal(
  p_user_id uuid,
  p_event_code text,
  p_event_key text,
  p_certification_reference text,
  p_occurred_at timestamptz default clock_timestamp(),
  p_league_id uuid default null,
  p_league_round_id uuid default null,
  p_season_id uuid default null,
  p_prediction_result_id uuid default null,
  p_correlation_id uuid default null,
  p_causation_id uuid default null,
  p_payload jsonb default '{}'::jsonb,
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_event_code text := upper(trim(p_event_code));
  v_event_key text := nullif(trim(p_event_key), '');
  v_certification_reference text :=
    nullif(trim(p_certification_reference), '');
  v_existing public.loyalty_reward_runtime_inbox;
  v_inbox public.loyalty_reward_runtime_inbox;
  v_policy_exists boolean;
  v_correlation_id uuid := coalesce(p_correlation_id, gen_random_uuid());
begin
  if p_user_id is null then
    raise exception using
      errcode = '22004',
      message = 'LOYALTY_RUNTIME_USER_ID_REQUIRED';
  end if;

  if v_event_key is null
     or length(v_event_key) < 8
     or length(v_event_key) > 300 then
    raise exception using
      errcode = '22023',
      message = 'LOYALTY_RUNTIME_EVENT_KEY_INVALID';
  end if;

  if v_certification_reference is null
     or length(v_certification_reference) < 8
     or length(v_certification_reference) > 500 then
    raise exception using
      errcode = '22023',
      message = 'LOYALTY_RUNTIME_CERTIFICATION_REFERENCE_INVALID';
  end if;

  if jsonb_typeof(coalesce(p_payload, '{}'::jsonb)) <> 'object'
     or jsonb_typeof(coalesce(p_metadata, '{}'::jsonb)) <> 'object' then
    raise exception using
      errcode = '22023',
      message = 'LOYALTY_RUNTIME_JSON_OBJECT_REQUIRED';
  end if;

  select exists (
    select 1
    from public.loyalty_reward_policies
    where event_code = v_event_code
  )
  into v_policy_exists;

  if not v_policy_exists then
    raise exception using
      errcode = '22023',
      message = 'LOYALTY_RUNTIME_EVENT_CODE_NOT_REGISTERED';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('loyalty-runtime-event:' || v_event_key, 0)
  );

  select *
  into v_existing
  from public.loyalty_reward_runtime_inbox
  where event_key = v_event_key;

  if found then
    if v_existing.user_id is distinct from p_user_id
       or v_existing.event_code is distinct from v_event_code
       or v_existing.certification_reference
            is distinct from v_certification_reference then
      raise exception using
        errcode = '23505',
        message = 'LOYALTY_RUNTIME_EVENT_KEY_CONFLICT';
    end if;

    return jsonb_build_object(
      'enqueued', true,
      'created', false,
      'already_exists', true,
      'inbox_event_id', v_existing.id,
      'event_status', v_existing.event_status,
      'event_code', v_existing.event_code,
      'server_time', clock_timestamp()
    );
  end if;

  insert into public.loyalty_reward_runtime_inbox (
    event_code,
    event_key,
    certification_reference,
    user_id,
    league_id,
    league_round_id,
    season_id,
    prediction_result_id,
    event_status,
    correlation_id,
    causation_id,
    occurred_at,
    payload,
    metadata
  )
  values (
    v_event_code,
    v_event_key,
    v_certification_reference,
    p_user_id,
    p_league_id,
    p_league_round_id,
    p_season_id,
    p_prediction_result_id,
    'pending',
    v_correlation_id,
    p_causation_id,
    coalesce(p_occurred_at, clock_timestamp()),
    coalesce(p_payload, '{}'::jsonb),
    coalesce(p_metadata, '{}'::jsonb)
      || jsonb_build_object(
        'runtime_version', '1.0',
        'certified_event', true,
        'frontend_origin_allowed', false
      )
  )
  returning * into v_inbox;

  perform public.commercial_append_event_internal(
    'LOYALTY_RUNTIME_EVENT_ENQUEUED',
    'LOYALTY_RUNTIME_EVENT',
    v_inbox.id,
    v_inbox.user_id,
    v_inbox.correlation_id,
    v_inbox.causation_id,
    jsonb_build_object(
      'inbox_event_id', v_inbox.id,
      'event_code', v_inbox.event_code,
      'event_key', v_inbox.event_key,
      'certification_reference', v_inbox.certification_reference
    )
  );

  return jsonb_build_object(
    'enqueued', true,
    'created', true,
    'already_exists', false,
    'inbox_event_id', v_inbox.id,
    'event_status', v_inbox.event_status,
    'event_code', v_inbox.event_code,
    'server_time', clock_timestamp()
  );
end;
$$;

-- ============================================================================
-- 5. CLAIM NEXT RUNTIME EVENT
-- ============================================================================

create or replace function public.claim_next_loyalty_reward_runtime_event_internal(
  p_worker_id text,
  p_lease_seconds integer default 120
)
returns public.loyalty_reward_runtime_inbox
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_worker_id text := nullif(trim(p_worker_id), '');
  v_lease_seconds integer :=
    least(greatest(coalesce(p_lease_seconds, 120), 30), 900);
  v_event public.loyalty_reward_runtime_inbox;
begin
  if v_worker_id is null or length(v_worker_id) < 3 then
    raise exception using
      errcode = '22023',
      message = 'LOYALTY_RUNTIME_WORKER_ID_INVALID';
  end if;

  select *
  into v_event
  from public.loyalty_reward_runtime_inbox
  where
    (
      event_status in ('pending', 'retry_scheduled')
      and available_at <= clock_timestamp()
    )
    or
    (
      event_status in ('leased', 'processing')
      and lease_expires_at <= clock_timestamp()
    )
  order by
    available_at asc,
    received_at asc,
    id asc
  for update skip locked
  limit 1;

  if not found then
    return null;
  end if;

  update public.loyalty_reward_runtime_inbox
  set
    event_status = 'leased',
    lease_owner = v_worker_id,
    leased_at = clock_timestamp(),
    lease_expires_at =
      clock_timestamp() + make_interval(secs => v_lease_seconds),
    last_error_code = null,
    last_error_message = null
  where id = v_event.id
  returning * into v_event;

  return v_event;
end;
$$;

-- ============================================================================
-- 6. RETRY DELAY
-- ============================================================================

create or replace function public.loyalty_reward_runtime_retry_delay_seconds(
  p_attempt_count integer
)
returns integer
language sql
immutable
strict
set search_path = public, pg_temp
as $$
  select least(
    3600,
    greatest(
      30,
      (30 * power(2, least(greatest(p_attempt_count - 1, 0), 7)))::integer
    )
  );
$$;

-- ============================================================================
-- 7. PROCESS ONE CLAIMED EVENT
-- ============================================================================

create or replace function public.process_loyalty_reward_runtime_event_internal(
  p_inbox_event_id uuid,
  p_worker_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_worker_id text := nullif(trim(p_worker_id), '');
  v_inbox public.loyalty_reward_runtime_inbox;
  v_attempt public.loyalty_reward_runtime_attempts;
  v_award_result jsonb;
  v_loyalty_event_id uuid;
  v_error_code text;
  v_error_message text;
  v_delay_seconds integer;
  v_terminal_status text;
begin
  if p_inbox_event_id is null then
    raise exception using
      errcode = '22004',
      message = 'LOYALTY_RUNTIME_INBOX_EVENT_ID_REQUIRED';
  end if;

  if v_worker_id is null or length(v_worker_id) < 3 then
    raise exception using
      errcode = '22023',
      message = 'LOYALTY_RUNTIME_WORKER_ID_INVALID';
  end if;

  select *
  into v_inbox
  from public.loyalty_reward_runtime_inbox
  where id = p_inbox_event_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'LOYALTY_RUNTIME_INBOX_EVENT_NOT_FOUND';
  end if;

  if v_inbox.event_status in ('rewarded', 'skipped', 'dead_letter') then
    return jsonb_build_object(
      'processed', true,
      'already_terminal', true,
      'inbox_event_id', v_inbox.id,
      'event_status', v_inbox.event_status,
      'loyalty_reward_event_id', v_inbox.loyalty_reward_event_id,
      'server_time', clock_timestamp()
    );
  end if;

  if v_inbox.event_status <> 'leased'
     or v_inbox.lease_owner is distinct from v_worker_id
     or v_inbox.lease_expires_at <= clock_timestamp() then
    raise exception using
      errcode = '55000',
      message = 'LOYALTY_RUNTIME_VALID_LEASE_REQUIRED';
  end if;

  update public.loyalty_reward_runtime_inbox
  set
    event_status = 'processing',
    processing_started_at = clock_timestamp(),
    attempt_count = attempt_count + 1
  where id = v_inbox.id
  returning * into v_inbox;

  insert into public.loyalty_reward_runtime_attempts (
    inbox_event_id,
    attempt_number,
    worker_id,
    attempt_status,
    correlation_id,
    causation_id
  )
  values (
    v_inbox.id,
    v_inbox.attempt_count,
    v_worker_id,
    'processing',
    v_inbox.correlation_id,
    v_inbox.causation_id
  )
  returning * into v_attempt;

  begin
    v_award_result := public.award_loyalty_reward_internal(
      v_inbox.user_id,
      v_inbox.event_code,
      v_inbox.event_key,
      v_inbox.certification_reference,
      v_inbox.occurred_at,
      v_inbox.league_id,
      v_inbox.league_round_id,
      v_inbox.season_id,
      v_inbox.prediction_result_id,
      v_inbox.correlation_id,
      v_inbox.causation_id,
      v_inbox.payload,
      v_inbox.metadata
        || jsonb_build_object(
          'runtime_inbox_event_id', v_inbox.id,
          'runtime_attempt_id', v_attempt.id,
          'runtime_worker_id', v_worker_id
        )
    );

    if coalesce((v_award_result ->> 'rewarded')::boolean, false) then
      v_terminal_status := 'rewarded';
      v_loyalty_event_id :=
        nullif(v_award_result ->> 'event_id', '')::uuid;
    elsif v_award_result ->> 'error_code' in (
      'LOYALTY_REWARD_POLICY_DISABLED',
      'LOYALTY_REWARD_CAMPAIGN_OR_SOURCE_DISABLED'
    ) then
      v_terminal_status := 'skipped';
    else
      v_error_code := coalesce(
        nullif(v_award_result ->> 'error_code', ''),
        'LOYALTY_RUNTIME_AWARD_NOT_COMPLETED'
      );
      raise exception using
        errcode = 'P0001',
        message = v_error_code;
    end if;

    update public.loyalty_reward_runtime_inbox
    set
      event_status = v_terminal_status,
      processed_at = clock_timestamp(),
      loyalty_reward_event_id = v_loyalty_event_id,
      lease_owner = null,
      leased_at = null,
      lease_expires_at = null,
      last_error_code = case
        when v_terminal_status = 'skipped'
        then v_award_result ->> 'error_code'
        else null
      end,
      last_error_message = null
    where id = v_inbox.id
    returning * into v_inbox;

    update public.loyalty_reward_runtime_attempts
    set
      attempt_status = v_terminal_status,
      completed_at = clock_timestamp(),
      error_code = case
        when v_terminal_status = 'skipped'
        then v_award_result ->> 'error_code'
        else null
      end,
      award_result = v_award_result
    where id = v_attempt.id;

    perform public.commercial_append_event_internal(
      case
        when v_terminal_status = 'rewarded'
          then 'LOYALTY_RUNTIME_EVENT_REWARDED'
        else 'LOYALTY_RUNTIME_EVENT_SKIPPED'
      end,
      'LOYALTY_RUNTIME_EVENT',
      v_inbox.id,
      v_inbox.user_id,
      v_inbox.correlation_id,
      v_inbox.causation_id,
      jsonb_build_object(
        'inbox_event_id', v_inbox.id,
        'event_code', v_inbox.event_code,
        'event_status', v_terminal_status,
        'loyalty_reward_event_id', v_loyalty_event_id,
        'award_result', v_award_result
      )
    );

    return jsonb_build_object(
      'processed', true,
      'rewarded', v_terminal_status = 'rewarded',
      'skipped', v_terminal_status = 'skipped',
      'inbox_event_id', v_inbox.id,
      'event_status', v_inbox.event_status,
      'loyalty_reward_event_id', v_inbox.loyalty_reward_event_id,
      'award_result', v_award_result,
      'server_time', clock_timestamp()
    );

  exception
    when others then
      v_error_code := coalesce(nullif(sqlstate, ''), 'P0001');
      v_error_message := left(sqlerrm, 2000);

      if v_inbox.attempt_count >= v_inbox.max_attempts then
        v_terminal_status := 'dead_letter';

        update public.loyalty_reward_runtime_inbox
        set
          event_status = 'dead_letter',
          dead_lettered_at = clock_timestamp(),
          failed_at = clock_timestamp(),
          lease_owner = null,
          leased_at = null,
          lease_expires_at = null,
          last_error_code = v_error_code,
          last_error_message = v_error_message
        where id = v_inbox.id
        returning * into v_inbox;
      else
        v_terminal_status := 'retry_scheduled';
        v_delay_seconds :=
          public.loyalty_reward_runtime_retry_delay_seconds(
            v_inbox.attempt_count
          );

        update public.loyalty_reward_runtime_inbox
        set
          event_status = 'retry_scheduled',
          available_at =
            clock_timestamp() + make_interval(secs => v_delay_seconds),
          failed_at = clock_timestamp(),
          lease_owner = null,
          leased_at = null,
          lease_expires_at = null,
          last_error_code = v_error_code,
          last_error_message = v_error_message
        where id = v_inbox.id
        returning * into v_inbox;
      end if;

      update public.loyalty_reward_runtime_attempts
      set
        attempt_status = v_terminal_status,
        completed_at = clock_timestamp(),
        error_code = v_error_code,
        error_message = v_error_message,
        award_result = coalesce(v_award_result, '{}'::jsonb)
      where id = v_attempt.id;

      perform public.commercial_append_event_internal(
        case
          when v_terminal_status = 'dead_letter'
            then 'LOYALTY_RUNTIME_EVENT_DEAD_LETTERED'
          else 'LOYALTY_RUNTIME_EVENT_RETRY_SCHEDULED'
        end,
        'LOYALTY_RUNTIME_EVENT',
        v_inbox.id,
        v_inbox.user_id,
        v_inbox.correlation_id,
        v_inbox.causation_id,
        jsonb_build_object(
          'inbox_event_id', v_inbox.id,
          'event_code', v_inbox.event_code,
          'event_status', v_terminal_status,
          'attempt_count', v_inbox.attempt_count,
          'max_attempts', v_inbox.max_attempts,
          'retry_delay_seconds', v_delay_seconds,
          'error_code', v_error_code,
          'error_message', v_error_message
        )
      );

      return jsonb_build_object(
        'processed', false,
        'retry_scheduled', v_terminal_status = 'retry_scheduled',
        'dead_lettered', v_terminal_status = 'dead_letter',
        'inbox_event_id', v_inbox.id,
        'event_status', v_inbox.event_status,
        'attempt_count', v_inbox.attempt_count,
        'max_attempts', v_inbox.max_attempts,
        'available_at', v_inbox.available_at,
        'error_code', v_error_code,
        'error_message', v_error_message,
        'server_time', clock_timestamp()
      );
  end;
end;
$$;

-- ============================================================================
-- 8. DISPATCH BATCH
-- ============================================================================

create or replace function public.dispatch_loyalty_reward_runtime_batch_internal(
  p_worker_id text,
  p_limit integer default 25,
  p_lease_seconds integer default 120
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 25), 1), 200);
  v_claimed public.loyalty_reward_runtime_inbox;
  v_result jsonb;
  v_results jsonb := '[]'::jsonb;
  v_claimed_count integer := 0;
  v_rewarded_count integer := 0;
  v_skipped_count integer := 0;
  v_retry_count integer := 0;
  v_dead_letter_count integer := 0;
begin
  for v_claimed_count in 1..v_limit loop
    v_claimed :=
      public.claim_next_loyalty_reward_runtime_event_internal(
        p_worker_id,
        p_lease_seconds
      );

    exit when v_claimed.id is null;

    v_result :=
      public.process_loyalty_reward_runtime_event_internal(
        v_claimed.id,
        p_worker_id
      );

    v_results := v_results || jsonb_build_array(v_result);

    if coalesce((v_result ->> 'rewarded')::boolean, false) then
      v_rewarded_count := v_rewarded_count + 1;
    end if;

    if coalesce((v_result ->> 'skipped')::boolean, false) then
      v_skipped_count := v_skipped_count + 1;
    end if;

    if coalesce((v_result ->> 'retry_scheduled')::boolean, false) then
      v_retry_count := v_retry_count + 1;
    end if;

    if coalesce((v_result ->> 'dead_lettered')::boolean, false) then
      v_dead_letter_count := v_dead_letter_count + 1;
    end if;
  end loop;

  return jsonb_build_object(
    'worker_id', p_worker_id,
    'processed_count', jsonb_array_length(v_results),
    'rewarded_count', v_rewarded_count,
    'skipped_count', v_skipped_count,
    'retry_scheduled_count', v_retry_count,
    'dead_letter_count', v_dead_letter_count,
    'results', v_results,
    'server_time', clock_timestamp()
  );
end;
$$;

-- ============================================================================
-- 9. LEASE RECONCILIATION
-- ============================================================================

create or replace function public.reconcile_expired_loyalty_reward_leases_internal(
  p_limit integer default 500
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 500), 1), 5000);
  v_released integer := 0;
begin
  with expired as (
    select id
    from public.loyalty_reward_runtime_inbox
    where event_status in ('leased', 'processing')
      and lease_expires_at <= clock_timestamp()
    order by lease_expires_at asc
    for update skip locked
    limit v_limit
  )
  update public.loyalty_reward_runtime_inbox i
  set
    event_status = 'retry_scheduled',
    available_at = clock_timestamp(),
    lease_owner = null,
    leased_at = null,
    lease_expires_at = null,
    last_error_code = 'LOYALTY_RUNTIME_LEASE_EXPIRED',
    last_error_message = 'Expired runtime lease released by reconciliation.'
  from expired e
  where i.id = e.id;

  get diagnostics v_released = row_count;

  return jsonb_build_object(
    'released_count', v_released,
    'server_time', clock_timestamp()
  );
end;
$$;

-- ============================================================================
-- 10. ADMINISTRATIVE DEAD-LETTER REQUEUE
-- ============================================================================

create or replace function public.requeue_loyalty_reward_dead_letter_internal(
  p_inbox_event_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_reason text := nullif(trim(p_reason), '');
  v_event public.loyalty_reward_runtime_inbox;
begin
  if v_reason is null or length(v_reason) < 8 then
    raise exception using
      errcode = '22023',
      message = 'LOYALTY_RUNTIME_REQUEUE_REASON_REQUIRED';
  end if;

  select *
  into v_event
  from public.loyalty_reward_runtime_inbox
  where id = p_inbox_event_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'LOYALTY_RUNTIME_INBOX_EVENT_NOT_FOUND';
  end if;

  if v_event.event_status <> 'dead_letter' then
    raise exception using
      errcode = '55000',
      message = 'LOYALTY_RUNTIME_EVENT_NOT_DEAD_LETTER';
  end if;

  update public.loyalty_reward_runtime_inbox
  set
    event_status = 'retry_scheduled',
    available_at = clock_timestamp(),
    attempt_count = 0,
    failed_at = null,
    dead_lettered_at = null,
    last_error_code = null,
    last_error_message = null,
    metadata = metadata || jsonb_build_object(
      'last_manual_requeue_reason', v_reason,
      'last_manual_requeue_at', clock_timestamp()
    )
  where id = v_event.id
  returning * into v_event;

  perform public.commercial_append_event_internal(
    'LOYALTY_RUNTIME_DEAD_LETTER_REQUEUED',
    'LOYALTY_RUNTIME_EVENT',
    v_event.id,
    v_event.user_id,
    v_event.correlation_id,
    v_event.causation_id,
    jsonb_build_object(
      'inbox_event_id', v_event.id,
      'event_code', v_event.event_code,
      'reason', v_reason
    )
  );

  return jsonb_build_object(
    'requeued', true,
    'inbox_event_id', v_event.id,
    'event_status', v_event.event_status,
    'server_time', clock_timestamp()
  );
end;
$$;

-- ============================================================================
-- 11. EVENT-SPECIFIC PRODUCER ADAPTERS
-- ============================================================================

create or replace function public.enqueue_certified_prediction_loyalty_event_internal(
  p_user_id uuid,
  p_event_code text,
  p_prediction_result_id uuid,
  p_certification_reference text,
  p_league_id uuid,
  p_league_round_id uuid,
  p_season_id uuid default null,
  p_occurred_at timestamptz default clock_timestamp(),
  p_correlation_id uuid default null,
  p_causation_id uuid default null,
  p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_event_code text := upper(trim(p_event_code));
begin
  if v_event_code not in (
    'CERTIFIED_EXACT_ACHIEVED',
    'CERTIFIED_GRAND_SLAM_ACHIEVED',
    'CERTIFIED_CANTONATA_ACHIEVED'
  ) then
    raise exception using
      errcode = '22023',
      message = 'LOYALTY_RUNTIME_PREDICTION_EVENT_CODE_INVALID';
  end if;

  if p_prediction_result_id is null then
    raise exception using
      errcode = '22004',
      message = 'LOYALTY_RUNTIME_PREDICTION_RESULT_ID_REQUIRED';
  end if;

  return public.enqueue_loyalty_certified_event_internal(
    p_user_id,
    v_event_code,
    'prediction-result:' || p_prediction_result_id::text || ':' || v_event_code,
    p_certification_reference,
    p_occurred_at,
    p_league_id,
    p_league_round_id,
    p_season_id,
    p_prediction_result_id,
    p_correlation_id,
    p_causation_id,
    coalesce(p_payload, '{}'::jsonb),
    jsonb_build_object(
      'producer_adapter', 'certified_prediction_loyalty_event',
      'producer_version', '1.0'
    )
  );
end;
$$;

create or replace function public.enqueue_certified_league_loyalty_event_internal(
  p_user_id uuid,
  p_event_code text,
  p_league_id uuid,
  p_certification_reference text,
  p_league_round_id uuid default null,
  p_season_id uuid default null,
  p_occurred_at timestamptz default clock_timestamp(),
  p_correlation_id uuid default null,
  p_causation_id uuid default null,
  p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_event_code text := upper(trim(p_event_code));
  v_scope_key text;
begin
  if v_event_code not in (
    'LEAGUE_REACHED_8_ACTIVE_MEMBERS',
    'LEAGUE_FIRST_ROUND_CERTIFIED',
    'LEAGUE_SEASON_CERTIFIED_COMPLETE'
  ) then
    raise exception using
      errcode = '22023',
      message = 'LOYALTY_RUNTIME_LEAGUE_EVENT_CODE_INVALID';
  end if;

  if p_league_id is null then
    raise exception using
      errcode = '22004',
      message = 'LOYALTY_RUNTIME_LEAGUE_ID_REQUIRED';
  end if;

  v_scope_key := case v_event_code
    when 'LEAGUE_REACHED_8_ACTIVE_MEMBERS'
      then 'league:' || p_league_id::text
    when 'LEAGUE_FIRST_ROUND_CERTIFIED'
      then 'league-round:' || coalesce(
        p_league_round_id::text,
        'missing'
      )
    when 'LEAGUE_SEASON_CERTIFIED_COMPLETE'
      then 'league-season:' || p_league_id::text || ':' || coalesce(
        p_season_id::text,
        'missing'
      )
  end;

  return public.enqueue_loyalty_certified_event_internal(
    p_user_id,
    v_event_code,
    v_scope_key || ':' || v_event_code,
    p_certification_reference,
    p_occurred_at,
    p_league_id,
    p_league_round_id,
    p_season_id,
    null,
    p_correlation_id,
    p_causation_id,
    coalesce(p_payload, '{}'::jsonb),
    jsonb_build_object(
      'producer_adapter', 'certified_league_loyalty_event',
      'producer_version', '1.0'
    )
  );
end;
$$;

create or replace function public.enqueue_certified_participation_loyalty_event_internal(
  p_user_id uuid,
  p_event_code text,
  p_certification_reference text,
  p_league_id uuid default null,
  p_league_round_id uuid default null,
  p_season_id uuid default null,
  p_occurred_at timestamptz default clock_timestamp(),
  p_correlation_id uuid default null,
  p_causation_id uuid default null,
  p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_event_code text := upper(trim(p_event_code));
  v_scope_key text;
begin
  if v_event_code not in (
    'PROFILE_COMPLETED_AFTER_FIRST_LEAGUE_ROUND',
    'COMPLETE_PREDICTIONS_STREAK_5_CERTIFIED',
    'COMPLETE_PREDICTIONS_STREAK_10_CERTIFIED',
    'COMPLETE_PREDICTIONS_FULL_SEASON_CERTIFIED'
  ) then
    raise exception using
      errcode = '22023',
      message = 'LOYALTY_RUNTIME_PARTICIPATION_EVENT_CODE_INVALID';
  end if;

  v_scope_key := case v_event_code
    when 'PROFILE_COMPLETED_AFTER_FIRST_LEAGUE_ROUND'
      then 'account:' || p_user_id::text
    when 'COMPLETE_PREDICTIONS_STREAK_5_CERTIFIED'
      then 'streak-5:' || p_user_id::text || ':' ||
        coalesce(p_league_id::text, 'missing') || ':' ||
        coalesce(p_season_id::text, 'missing')
    when 'COMPLETE_PREDICTIONS_STREAK_10_CERTIFIED'
      then 'streak-10:' || p_user_id::text || ':' ||
        coalesce(p_league_id::text, 'missing') || ':' ||
        coalesce(p_season_id::text, 'missing')
    when 'COMPLETE_PREDICTIONS_FULL_SEASON_CERTIFIED'
      then 'full-season:' || p_user_id::text || ':' ||
        coalesce(p_league_id::text, 'missing') || ':' ||
        coalesce(p_season_id::text, 'missing')
  end;

  return public.enqueue_loyalty_certified_event_internal(
    p_user_id,
    v_event_code,
    v_scope_key || ':' || v_event_code,
    p_certification_reference,
    p_occurred_at,
    p_league_id,
    p_league_round_id,
    p_season_id,
    null,
    p_correlation_id,
    p_causation_id,
    coalesce(p_payload, '{}'::jsonb),
    jsonb_build_object(
      'producer_adapter', 'certified_participation_loyalty_event',
      'producer_version', '1.0'
    )
  );
end;
$$;

-- ============================================================================
-- 12. OPERATIONAL READ MODELS
-- ============================================================================

create or replace view public.loyalty_reward_runtime_status_v
with (security_invoker = true)
as
select
  i.id as inbox_event_id,
  i.event_code,
  i.event_key,
  i.user_id,
  i.league_id,
  i.league_round_id,
  i.season_id,
  i.prediction_result_id,
  i.event_status,
  i.attempt_count,
  i.max_attempts,
  i.available_at,
  i.lease_owner,
  i.lease_expires_at,
  i.loyalty_reward_event_id,
  i.last_error_code,
  i.last_error_message,
  i.correlation_id,
  i.causation_id,
  i.occurred_at,
  i.received_at,
  i.processed_at,
  i.dead_lettered_at,
  i.created_at,
  i.updated_at
from public.loyalty_reward_runtime_inbox i;

create or replace view public.loyalty_reward_runtime_health_v
with (security_invoker = true)
as
select
  count(*) filter (
    where event_status = 'pending'
  )::integer as pending_count,

  count(*) filter (
    where event_status = 'retry_scheduled'
  )::integer as retry_scheduled_count,

  count(*) filter (
    where event_status in ('leased', 'processing')
  )::integer as in_flight_count,

  count(*) filter (
    where event_status = 'rewarded'
  )::integer as rewarded_count,

  count(*) filter (
    where event_status = 'skipped'
  )::integer as skipped_count,

  count(*) filter (
    where event_status = 'dead_letter'
  )::integer as dead_letter_count,

  min(available_at) filter (
    where event_status in ('pending', 'retry_scheduled')
  ) as oldest_available_at,

  max(processed_at) filter (
    where event_status in ('rewarded', 'skipped')
  ) as latest_processed_at,

  clock_timestamp() as server_time
from public.loyalty_reward_runtime_inbox;

comment on view public.loyalty_reward_runtime_status_v is
  'Backend operational status for loyalty reward runtime events.';

comment on view public.loyalty_reward_runtime_health_v is
  'Backend health projection for the loyalty reward runtime queue.';

-- ============================================================================
-- 13. ROW LEVEL SECURITY
-- ============================================================================

alter table public.loyalty_reward_runtime_inbox enable row level security;
alter table public.loyalty_reward_runtime_attempts enable row level security;

-- No client policies. Runtime remains backend-only.

-- ============================================================================
-- 14. PRIVILEGES
-- ============================================================================

revoke all on table public.loyalty_reward_runtime_inbox
  from public, anon, authenticated;

revoke all on table public.loyalty_reward_runtime_attempts
  from public, anon, authenticated;

revoke all on table public.loyalty_reward_runtime_status_v
  from public, anon, authenticated;

revoke all on table public.loyalty_reward_runtime_health_v
  from public, anon, authenticated;

grant all on table public.loyalty_reward_runtime_inbox
  to service_role;

grant all on table public.loyalty_reward_runtime_attempts
  to service_role;

grant select on table public.loyalty_reward_runtime_status_v
  to service_role;

grant select on table public.loyalty_reward_runtime_health_v
  to service_role;

revoke all on function public.enqueue_loyalty_certified_event_internal(
  uuid, text, text, text, timestamptz,
  uuid, uuid, uuid, uuid, uuid, uuid, jsonb, jsonb
) from public, anon, authenticated;

revoke all on function public.claim_next_loyalty_reward_runtime_event_internal(
  text, integer
) from public, anon, authenticated;

revoke all on function public.loyalty_reward_runtime_retry_delay_seconds(
  integer
) from public, anon, authenticated;

revoke all on function public.process_loyalty_reward_runtime_event_internal(
  uuid, text
) from public, anon, authenticated;

revoke all on function public.dispatch_loyalty_reward_runtime_batch_internal(
  text, integer, integer
) from public, anon, authenticated;

revoke all on function public.reconcile_expired_loyalty_reward_leases_internal(
  integer
) from public, anon, authenticated;

revoke all on function public.requeue_loyalty_reward_dead_letter_internal(
  uuid, text
) from public, anon, authenticated;

revoke all on function public.enqueue_certified_prediction_loyalty_event_internal(
  uuid, text, uuid, text, uuid, uuid, uuid,
  timestamptz, uuid, uuid, jsonb
) from public, anon, authenticated;

revoke all on function public.enqueue_certified_league_loyalty_event_internal(
  uuid, text, uuid, text, uuid, uuid,
  timestamptz, uuid, uuid, jsonb
) from public, anon, authenticated;

revoke all on function public.enqueue_certified_participation_loyalty_event_internal(
  uuid, text, text, uuid, uuid, uuid,
  timestamptz, uuid, uuid, jsonb
) from public, anon, authenticated;

grant execute on function public.enqueue_loyalty_certified_event_internal(
  uuid, text, text, text, timestamptz,
  uuid, uuid, uuid, uuid, uuid, uuid, jsonb, jsonb
) to service_role;

grant execute on function public.claim_next_loyalty_reward_runtime_event_internal(
  text, integer
) to service_role;

grant execute on function public.loyalty_reward_runtime_retry_delay_seconds(
  integer
) to service_role;

grant execute on function public.process_loyalty_reward_runtime_event_internal(
  uuid, text
) to service_role;

grant execute on function public.dispatch_loyalty_reward_runtime_batch_internal(
  text, integer, integer
) to service_role;

grant execute on function public.reconcile_expired_loyalty_reward_leases_internal(
  integer
) to service_role;

grant execute on function public.requeue_loyalty_reward_dead_letter_internal(
  uuid, text
) to service_role;

grant execute on function public.enqueue_certified_prediction_loyalty_event_internal(
  uuid, text, uuid, text, uuid, uuid, uuid,
  timestamptz, uuid, uuid, jsonb
) to service_role;

grant execute on function public.enqueue_certified_league_loyalty_event_internal(
  uuid, text, uuid, text, uuid, uuid,
  timestamptz, uuid, uuid, jsonb
) to service_role;

grant execute on function public.enqueue_certified_participation_loyalty_event_internal(
  uuid, text, text, uuid, uuid, uuid,
  timestamptz, uuid, uuid, jsonb
) to service_role;

-- ============================================================================
-- 15. FINAL ASSERTIONS
-- ============================================================================

do $$
declare
  v_policy_count integer;
  v_enabled_policy_count integer;
  v_enabled_campaign_count integer;
  v_enabled_source_count integer;
begin
  select count(*)
  into v_policy_count
  from public.loyalty_reward_policies;

  if v_policy_count <> 10 then
    raise exception using
      errcode = 'P0001',
      message = 'LOYALTY_RUNTIME_EXPECTED_10_POLICIES';
  end if;

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

  if v_enabled_policy_count <> 0
     or v_enabled_campaign_count <> 0
     or v_enabled_source_count <> 0 then
    raise exception using
      errcode = 'P0001',
      message = 'LOYALTY_RUNTIME_MUST_NOT_ACTIVATE_REWARDS';
  end if;

  if to_regprocedure(
    'public.enqueue_loyalty_certified_event_internal(uuid,text,text,text,timestamp with time zone,uuid,uuid,uuid,uuid,uuid,uuid,jsonb,jsonb)'
  ) is null then
    raise exception using
      errcode = 'P0001',
      message = 'LOYALTY_RUNTIME_ENQUEUE_FUNCTION_MISSING';
  end if;

  if to_regprocedure(
    'public.dispatch_loyalty_reward_runtime_batch_internal(text,integer,integer)'
  ) is null then
    raise exception using
      errcode = 'P0001',
      message = 'LOYALTY_RUNTIME_DISPATCH_FUNCTION_MISSING';
  end if;

  raise notice 'LOYALTY REWARD RUNTIME INTEGRATION CERTIFIED';
  raise notice 'Certified workflow events can now be enqueued idempotently';
  raise notice 'Runtime supports lease, retry, reconciliation and dead-letter';
  raise notice 'All loyalty policies, campaigns and reward source remain disabled';
  raise notice 'No frontend path can create or dispatch loyalty rewards';
  raise notice 'Workflow producer calls and E2E activation tests remain pending';
end;
$$;

commit;
