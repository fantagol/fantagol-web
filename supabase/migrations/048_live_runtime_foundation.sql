-- ============================================================================
-- FANTAGOL
-- Migration 048: Live Runtime Foundation
--
-- Scope:
-- - persist the application-runtime job queue;
-- - deduplicate normalized provider match updates;
-- - persist immutable Live State Snapshots linked to Round Simulations;
-- - reuse round_simulation_publications as the single publication registry;
-- - persist terminal runtime failures in an append-only dead-letter registry;
-- - expose service-only orchestration RPCs and authenticated recovery queries.
--
-- Out of scope:
-- - provider HTTP calls;
-- - polling loops, cron scheduling or websocket processes;
-- - score, strategy, standings or UI recalculation;
-- - CSS, React or Android rendering;
-- - certification or Ranking Ledger mutation.
-- ============================================================================

begin;

-- ============================================================================
-- 1. LIVE RUNTIME JOBS
-- ============================================================================

create table if not exists public.live_runtime_jobs (
  id uuid primary key default gen_random_uuid(),
  job_type text not null,
  status text not null default 'pending',
  priority integer not null default 100,
  scope_type text not null,
  scope_id uuid not null,
  scheduled_at timestamptz not null default now(),
  claimed_at timestamptz null,
  claimed_by text null,
  attempt_count integer not null default 0,
  max_attempts integer not null default 5,
  idempotency_key text not null,
  correlation_id uuid not null default gen_random_uuid(),
  causation_id uuid null,
  payload jsonb not null default '{}'::jsonb,
  result jsonb not null default '{}'::jsonb,
  last_error jsonb null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz null,
  failed_at timestamptz null,
  cancelled_at timestamptz null,

  constraint live_runtime_jobs_type_check
    check (
      job_type in (
        'poll_match',
        'refresh_round',
        'rebuild_league_round',
        'publish_snapshot',
        'retry_publication',
        'evaluate_certification_readiness'
      )
    ),

  constraint live_runtime_jobs_status_check
    check (
      status in (
        'pending',
        'claimed',
        'running',
        'completed',
        'failed',
        'retry_wait',
        'dead_letter',
        'cancelled'
      )
    ),

  constraint live_runtime_jobs_scope_check
    check (
      scope_type in (
        'match',
        'fantagol_round',
        'league_round',
        'round_simulation',
        'live_state_snapshot',
        'publication'
      )
    ),

  constraint live_runtime_jobs_priority_check
    check (priority >= 0),

  constraint live_runtime_jobs_attempts_check
    check (
      attempt_count >= 0
      and max_attempts > 0
      and attempt_count <= max_attempts
    ),

  constraint live_runtime_jobs_identity_check
    check (
      btrim(idempotency_key) <> ''
      and btrim(scope_type) <> ''
    ),

  constraint live_runtime_jobs_claim_check
    check (
      (
        status in ('pending', 'retry_wait')
        and claimed_at is null
        and claimed_by is null
      )
      or (
        status in ('claimed', 'running', 'completed', 'failed', 'dead_letter')
        and claimed_at is not null
        and nullif(btrim(claimed_by), '') is not null
      )
      or status = 'cancelled'
    ),

  constraint live_runtime_jobs_completion_check
    check (
      (status = 'completed' and completed_at is not null)
      or (status <> 'completed' and completed_at is null)
    ),

  constraint live_runtime_jobs_failure_check
    check (
      (
        status in ('failed', 'dead_letter')
        and failed_at is not null
        and last_error is not null
      )
      or (
        status not in ('failed', 'dead_letter')
        and failed_at is null
      )
    ),

  constraint live_runtime_jobs_cancel_check
    check (
      (status = 'cancelled' and cancelled_at is not null)
      or (status <> 'cancelled' and cancelled_at is null)
    ),

  constraint live_runtime_jobs_dates_check
    check (
      updated_at >= created_at
      and (claimed_at is null or claimed_at >= created_at)
      and (completed_at is null or completed_at >= created_at)
      and (failed_at is null or failed_at >= created_at)
      and (cancelled_at is null or cancelled_at >= created_at)
    ),

  constraint live_runtime_jobs_idempotency_unique
    unique (idempotency_key)
);

create index if not exists live_runtime_jobs_claim_idx
  on public.live_runtime_jobs(
    priority asc,
    scheduled_at asc,
    created_at asc
  )
  where status in ('pending', 'retry_wait');

create index if not exists live_runtime_jobs_scope_idx
  on public.live_runtime_jobs(scope_type, scope_id, created_at desc);

create index if not exists live_runtime_jobs_status_idx
  on public.live_runtime_jobs(status, scheduled_at);

create index if not exists live_runtime_jobs_correlation_idx
  on public.live_runtime_jobs(correlation_id);

-- ============================================================================
-- 2. LIVE MATCH UPDATE RECEIPTS
-- ============================================================================

create table if not exists public.live_match_update_receipts (
  id uuid primary key default gen_random_uuid(),
  provider_id uuid not null
    references public.data_providers(id)
    on delete restrict,
  external_match_id text not null,
  match_id uuid null
    references public.matches(id)
    on delete set null,
  provider_updated_at timestamptz not null,
  payload_hash text not null,
  received_at timestamptz not null default clock_timestamp(),
  normalized_payload jsonb not null default '{}'::jsonb,
  meaningful_change boolean null,
  change_type text null,
  processing_status text not null default 'received',
  processing_error jsonb null,
  correlation_id uuid not null default gen_random_uuid(),
  processed_at timestamptz null,
  created_at timestamptz not null default now(),

  constraint live_match_update_receipts_external_id_check
    check (btrim(external_match_id) <> ''),

  constraint live_match_update_receipts_hash_check
    check (payload_hash ~ '^[0-9a-f]{64}$'),

  constraint live_match_update_receipts_change_type_check
    check (
      change_type is null
      or change_type in (
        'NO_CHANGE',
        'MATCH_STATE_CHANGED',
        'MATCH_SCORE_CHANGED',
        'MATCH_KICKOFF_CHANGED',
        'MATCH_POSTPONED',
        'MATCH_CANCELLED',
        'MATCH_FINISHED',
        'MATCH_AWARDED'
      )
    ),

  constraint live_match_update_receipts_processing_status_check
    check (
      processing_status in (
        'received',
        'accepted',
        'duplicate',
        'processed',
        'rejected',
        'failed'
      )
    ),

  constraint live_match_update_receipts_processing_check
    check (
      (
        processing_status in ('processed', 'rejected', 'failed')
        and processed_at is not null
      )
      or (
        processing_status not in ('processed', 'rejected', 'failed')
        and processed_at is null
      )
    ),

  constraint live_match_update_receipts_error_check
    check (
      (processing_status = 'failed' and processing_error is not null)
      or processing_status <> 'failed'
    ),

  constraint live_match_update_receipts_dates_check
    check (
      received_at <= created_at + interval '5 minutes'
      and (processed_at is null or processed_at >= received_at)
    ),

  constraint live_match_update_receipts_source_unique
    unique (
      provider_id,
      external_match_id,
      provider_updated_at,
      payload_hash
    )
);

create index if not exists live_match_update_receipts_match_idx
  on public.live_match_update_receipts(match_id, received_at desc);

create index if not exists live_match_update_receipts_provider_idx
  on public.live_match_update_receipts(
    provider_id,
    external_match_id,
    provider_updated_at desc
  );

create index if not exists live_match_update_receipts_status_idx
  on public.live_match_update_receipts(processing_status, received_at);

create index if not exists live_match_update_receipts_correlation_idx
  on public.live_match_update_receipts(correlation_id);

-- ============================================================================
-- 3. LIVE STATE SNAPSHOTS
-- ============================================================================

create table if not exists public.live_state_snapshots (
  id uuid primary key default gen_random_uuid(),
  league_round_id uuid not null
    references public.league_rounds(id)
    on delete cascade,
  simulation_id uuid not null
    references public.round_simulations(id)
    on delete restrict,
  live_state_version integer not null,
  engine_version text not null,
  snapshot_schema_version integer not null default 1,
  status text not null default 'ready',
  manifest jsonb not null,
  live_state jsonb not null,
  timeline_cursor jsonb not null default '{}'::jsonb,
  health jsonb not null default jsonb_build_object(
    'status', 'healthy',
    'stale', false
  ),
  input_hash text not null,
  output_hash text not null,
  snapshot_hash text not null,
  primary_publication_id uuid null
    references public.round_simulation_publications(id)
    on delete set null,
  correlation_id uuid not null default gen_random_uuid(),
  generated_at timestamptz not null default clock_timestamp(),
  published_at timestamptz null,
  superseded_at timestamptz null,
  invalidated_at timestamptz null,
  failed_at timestamptz null,
  failure_details jsonb null,
  created_at timestamptz not null default now(),

  constraint live_state_snapshots_version_check
    check (live_state_version > 0),

  constraint live_state_snapshots_engine_check
    check (btrim(engine_version) <> ''),

  constraint live_state_snapshots_schema_version_check
    check (snapshot_schema_version > 0),

  constraint live_state_snapshots_status_check
    check (
      status in (
        'building',
        'ready',
        'published',
        'superseded',
        'invalidated',
        'failed',
        'certified'
      )
    ),

  constraint live_state_snapshots_hashes_check
    check (
      input_hash ~ '^[0-9a-f]{64}$'
      and output_hash ~ '^[0-9a-f]{64}$'
      and snapshot_hash ~ '^[0-9a-f]{64}$'
    ),

  constraint live_state_snapshots_health_check
    check (
      coalesce(health ->> 'status', '') in (
        'healthy',
        'degraded',
        'stale',
        'failed'
      )
    ),

  constraint live_state_snapshots_publication_check
    check (
      (
        status in ('published', 'superseded', 'certified')
        and published_at is not null
      )
      or (
        status not in ('published', 'superseded', 'certified')
        and published_at is null
      )
    ),

  constraint live_state_snapshots_superseded_check
    check (
      (status = 'superseded' and superseded_at is not null)
      or (status <> 'superseded' and superseded_at is null)
    ),

  constraint live_state_snapshots_invalidated_check
    check (
      (status = 'invalidated' and invalidated_at is not null)
      or (status <> 'invalidated' and invalidated_at is null)
    ),

  constraint live_state_snapshots_failed_check
    check (
      (
        status = 'failed'
        and failed_at is not null
        and failure_details is not null
      )
      or (
        status <> 'failed'
        and failed_at is null
      )
    ),

  constraint live_state_snapshots_dates_check
    check (
      generated_at <= created_at + interval '5 minutes'
      and (published_at is null or published_at >= generated_at)
      and (superseded_at is null or superseded_at >= published_at)
      and (invalidated_at is null or invalidated_at >= generated_at)
      and (failed_at is null or failed_at >= generated_at)
    ),

  constraint live_state_snapshots_round_version_unique
    unique (league_round_id, live_state_version),

  constraint live_state_snapshots_simulation_engine_unique
    unique (simulation_id, engine_version)
);

create index if not exists live_state_snapshots_round_idx
  on public.live_state_snapshots(
    league_round_id,
    live_state_version desc
  );

create index if not exists live_state_snapshots_simulation_idx
  on public.live_state_snapshots(simulation_id);

create index if not exists live_state_snapshots_status_idx
  on public.live_state_snapshots(status, created_at desc);

create index if not exists live_state_snapshots_correlation_idx
  on public.live_state_snapshots(correlation_id);

-- ============================================================================
-- 4. LIVE RUNTIME DEAD LETTERS
-- ============================================================================

create table if not exists public.live_runtime_dead_letters (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null
    references public.live_runtime_jobs(id)
    on delete restrict,
  job_type text not null,
  scope_type text not null,
  scope_id uuid not null,
  attempt_count integer not null,
  correlation_id uuid not null,
  failure jsonb not null,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),

  constraint live_runtime_dead_letters_attempts_check
    check (attempt_count > 0),

  constraint live_runtime_dead_letters_failure_check
    check (failure <> '{}'::jsonb),

  constraint live_runtime_dead_letters_job_unique
    unique (job_id)
);

create index if not exists live_runtime_dead_letters_scope_idx
  on public.live_runtime_dead_letters(
    scope_type,
    scope_id,
    created_at desc
  );

create index if not exists live_runtime_dead_letters_correlation_idx
  on public.live_runtime_dead_letters(correlation_id);

-- ============================================================================
-- 5. GUARDS AND VALIDATORS
-- ============================================================================

create or replace function public.guard_live_runtime_append_only()
returns trigger
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
begin
  raise exception using
    errcode = 'P0001',
    message = 'LIVE_RUNTIME_APPEND_ONLY_OBJECT';
end;
$function$;

create or replace function public.validate_live_state_snapshot_source()
returns trigger
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
  v_simulation public.round_simulations%rowtype;
begin
  select rs.*
  into v_simulation
  from public.round_simulations rs
  where rs.id = new.simulation_id;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_SOURCE_SIMULATION_NOT_FOUND';
  end if;

  if v_simulation.league_round_id <> new.league_round_id then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_SOURCE_ROUND_MISMATCH';
  end if;

  if v_simulation.status not in (
       'preview_ready',
       'awaiting_certification',
       'certified'
     )
     or v_simulation.simulation_hash is null
     or not (v_simulation.digital_twin ? 'ui_snapshot') then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_SOURCE_UI_SNAPSHOT_NOT_READY',
      detail = v_simulation.status;
  end if;

  return new;
end;
$function$;

create or replace function public.guard_live_state_snapshot_update()
returns trigger
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
begin
  if new.id <> old.id
     or new.league_round_id <> old.league_round_id
     or new.simulation_id <> old.simulation_id
     or new.live_state_version <> old.live_state_version
     or new.engine_version <> old.engine_version
     or new.snapshot_schema_version <> old.snapshot_schema_version
     or new.manifest <> old.manifest
     or new.live_state <> old.live_state
     or new.timeline_cursor <> old.timeline_cursor
     or new.health <> old.health
     or new.input_hash <> old.input_hash
     or new.output_hash <> old.output_hash
     or new.snapshot_hash <> old.snapshot_hash
     or new.correlation_id <> old.correlation_id
     or new.generated_at <> old.generated_at
     or new.created_at <> old.created_at then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_STATE_SNAPSHOT_IMMUTABLE_PAYLOAD';
  end if;

  if old.status = new.status then
    return new;
  end if;

  if not (
    (old.status = 'building' and new.status in ('ready', 'failed'))
    or (old.status = 'ready' and new.status in ('published', 'invalidated', 'failed'))
    or (old.status = 'published' and new.status in ('superseded', 'certified'))
    or (old.status = 'certified' and new.status = 'superseded')
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_STATE_SNAPSHOT_TRANSITION_INVALID',
      detail = old.status || ' -> ' || new.status;
  end if;

  return new;
end;
$function$;

drop trigger if exists live_match_update_receipts_append_only_guard
  on public.live_match_update_receipts;

create trigger live_match_update_receipts_append_only_guard
before update or delete
on public.live_match_update_receipts
for each row
execute function public.guard_live_runtime_append_only();

drop trigger if exists live_runtime_dead_letters_append_only_guard
  on public.live_runtime_dead_letters;

create trigger live_runtime_dead_letters_append_only_guard
before update or delete
on public.live_runtime_dead_letters
for each row
execute function public.guard_live_runtime_append_only();

drop trigger if exists live_state_snapshots_source_guard
  on public.live_state_snapshots;

create trigger live_state_snapshots_source_guard
before insert or update of league_round_id, simulation_id
on public.live_state_snapshots
for each row
execute function public.validate_live_state_snapshot_source();

drop trigger if exists live_state_snapshots_update_guard
  on public.live_state_snapshots;

create trigger live_state_snapshots_update_guard
before update
on public.live_state_snapshots
for each row
execute function public.guard_live_state_snapshot_update();

-- ============================================================================
-- 6. RLS
-- ============================================================================

alter table public.live_runtime_jobs
  enable row level security;

alter table public.live_match_update_receipts
  enable row level security;

alter table public.live_state_snapshots
  enable row level security;

alter table public.live_runtime_dead_letters
  enable row level security;

drop policy if exists live_state_snapshots_select_members
  on public.live_state_snapshots;

create policy live_state_snapshots_select_members
on public.live_state_snapshots
for select
to authenticated
using (
  exists (
    select 1
    from public.league_rounds lr
    join public.league_members lm
      on lm.league_id = lr.league_id
    where lr.id = live_state_snapshots.league_round_id
      and lm.user_id = auth.uid()
      and lm.status = 'active'
  )
);

-- ============================================================================
-- 7. JOB RPCS
-- ============================================================================

create or replace function public.enqueue_live_runtime_job_rpc(
  p_job_type text,
  p_scope_type text,
  p_scope_id uuid,
  p_idempotency_key text,
  p_priority integer default 100,
  p_scheduled_at timestamptz default now(),
  p_payload jsonb default '{}'::jsonb,
  p_max_attempts integer default 5,
  p_correlation_id uuid default null,
  p_causation_id uuid default null
)
returns table (
  job_id uuid,
  job_status text,
  inserted boolean,
  scheduled_at timestamptz,
  attempt_count integer,
  correlation_id uuid
)
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
  v_job public.live_runtime_jobs%rowtype;
begin
  if p_scope_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_JOB_SCOPE_ID_REQUIRED';
  end if;

  if nullif(btrim(p_idempotency_key), '') is null then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_JOB_IDEMPOTENCY_KEY_REQUIRED';
  end if;

  insert into public.live_runtime_jobs (
    job_type,
    status,
    priority,
    scope_type,
    scope_id,
    scheduled_at,
    attempt_count,
    max_attempts,
    idempotency_key,
    correlation_id,
    causation_id,
    payload
  )
  values (
    p_job_type,
    'pending',
    p_priority,
    p_scope_type,
    p_scope_id,
    coalesce(p_scheduled_at, now()),
    0,
    p_max_attempts,
    btrim(p_idempotency_key),
    coalesce(p_correlation_id, gen_random_uuid()),
    p_causation_id,
    coalesce(p_payload, '{}'::jsonb)
  )
  on conflict (idempotency_key)
  do nothing
  returning *
  into v_job;

  if found then
    return query
    select
      v_job.id,
      v_job.status,
      true,
      v_job.scheduled_at,
      v_job.attempt_count,
      v_job.correlation_id;
    return;
  end if;

  select j.*
  into v_job
  from public.live_runtime_jobs j
  where j.idempotency_key = btrim(p_idempotency_key);

  return query
  select
    v_job.id,
    v_job.status,
    false,
    v_job.scheduled_at,
    v_job.attempt_count,
    v_job.correlation_id;
end;
$function$;

create or replace function public.claim_live_runtime_job_rpc(
  p_worker_id text,
  p_job_types text[] default null
)
returns table (
  job_id uuid,
  job_type text,
  job_status text,
  priority integer,
  scope_type text,
  scope_id uuid,
  scheduled_at timestamptz,
  attempt_count integer,
  max_attempts integer,
  correlation_id uuid,
  causation_id uuid,
  payload jsonb
)
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
  v_job public.live_runtime_jobs%rowtype;
begin
  if nullif(btrim(p_worker_id), '') is null then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_WORKER_ID_REQUIRED';
  end if;

  with candidate as (
    select j.id
    from public.live_runtime_jobs j
    where j.status in ('pending', 'retry_wait')
      and j.scheduled_at <= clock_timestamp()
      and (
        p_job_types is null
        or j.job_type = any (p_job_types)
      )
    order by
      j.priority asc,
      j.scheduled_at asc,
      j.created_at asc
    for update skip locked
    limit 1
  )
  update public.live_runtime_jobs j
  set
    status = 'running',
    claimed_at = clock_timestamp(),
    claimed_by = btrim(p_worker_id),
    attempt_count = j.attempt_count + 1,
    updated_at = clock_timestamp()
  from candidate c
  where j.id = c.id
  returning j.*
  into v_job;

  if not found then
    return;
  end if;

  return query
  select
    v_job.id,
    v_job.job_type,
    v_job.status,
    v_job.priority,
    v_job.scope_type,
    v_job.scope_id,
    v_job.scheduled_at,
    v_job.attempt_count,
    v_job.max_attempts,
    v_job.correlation_id,
    v_job.causation_id,
    v_job.payload;
end;
$function$;

create or replace function public.complete_live_runtime_job_rpc(
  p_job_id uuid,
  p_worker_id text,
  p_result jsonb default '{}'::jsonb
)
returns table (
  job_id uuid,
  job_status text,
  attempt_count integer,
  completed_at timestamptz,
  result jsonb
)
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
  v_job public.live_runtime_jobs%rowtype;
begin
  update public.live_runtime_jobs j
  set
    status = 'completed',
    result = coalesce(p_result, '{}'::jsonb),
    last_error = null,
    completed_at = clock_timestamp(),
    updated_at = clock_timestamp()
  where j.id = p_job_id
    and j.status in ('claimed', 'running')
    and j.claimed_by = btrim(p_worker_id)
  returning j.*
  into v_job;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_JOB_NOT_CLAIMED_BY_WORKER';
  end if;

  return query
  select
    v_job.id,
    v_job.status,
    v_job.attempt_count,
    v_job.completed_at,
    v_job.result;
end;
$function$;

create or replace function public.fail_live_runtime_job_rpc(
  p_job_id uuid,
  p_worker_id text,
  p_error jsonb,
  p_retry_delay_seconds integer default 30
)
returns table (
  job_id uuid,
  job_status text,
  attempt_count integer,
  max_attempts integer,
  scheduled_at timestamptz,
  dead_letter_id uuid
)
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
  v_job public.live_runtime_jobs%rowtype;
  v_dead_letter_id uuid;
  v_terminal boolean;
begin
  if p_error is null or p_error = '{}'::jsonb then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_JOB_ERROR_REQUIRED';
  end if;

  select j.*
  into v_job
  from public.live_runtime_jobs j
  where j.id = p_job_id
    and j.status in ('claimed', 'running')
    and j.claimed_by = btrim(p_worker_id)
  for update;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_JOB_NOT_CLAIMED_BY_WORKER';
  end if;

  v_terminal := v_job.attempt_count >= v_job.max_attempts;

  if v_terminal then
    update public.live_runtime_jobs
    set
      status = 'dead_letter',
      last_error = p_error,
      failed_at = clock_timestamp(),
      updated_at = clock_timestamp()
    where id = v_job.id
    returning *
    into v_job;

    insert into public.live_runtime_dead_letters (
      job_id,
      job_type,
      scope_type,
      scope_id,
      attempt_count,
      correlation_id,
      failure,
      payload
    )
    values (
      v_job.id,
      v_job.job_type,
      v_job.scope_type,
      v_job.scope_id,
      v_job.attempt_count,
      v_job.correlation_id,
      p_error,
      v_job.payload
    )
    on conflict on constraint live_runtime_dead_letters_job_unique
    do nothing
    returning id
    into v_dead_letter_id;

    if v_dead_letter_id is null then
      select dl.id
      into v_dead_letter_id
      from public.live_runtime_dead_letters dl
      where dl.job_id = v_job.id;
    end if;
  else
    update public.live_runtime_jobs
    set
      status = 'retry_wait',
      scheduled_at = clock_timestamp()
        + make_interval(secs => greatest(p_retry_delay_seconds, 0)),
      claimed_at = null,
      claimed_by = null,
      last_error = p_error,
      updated_at = clock_timestamp()
    where id = v_job.id
    returning *
    into v_job;
  end if;

  return query
  select
    v_job.id,
    v_job.status,
    v_job.attempt_count,
    v_job.max_attempts,
    v_job.scheduled_at,
    v_dead_letter_id;
end;
$function$;

-- ============================================================================
-- 8. PROVIDER RECEIPT RPC
-- ============================================================================

create or replace function public.register_live_match_update_rpc(
  p_provider_code text,
  p_external_match_id text,
  p_match_id uuid,
  p_provider_updated_at timestamptz,
  p_payload_hash text,
  p_normalized_payload jsonb,
  p_meaningful_change boolean default null,
  p_change_type text default null,
  p_correlation_id uuid default null
)
returns table (
  receipt_id uuid,
  inserted boolean,
  processing_status text,
  meaningful_change boolean,
  change_type text,
  correlation_id uuid
)
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
  v_provider_id uuid;
  v_receipt public.live_match_update_receipts%rowtype;
begin
  select dp.id
  into v_provider_id
  from public.data_providers dp
  where dp.code = btrim(p_provider_code)
    and dp.active = true
  order by dp.priority asc
  limit 1;

  if v_provider_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_PROVIDER_NOT_ACTIVE';
  end if;

  if nullif(btrim(p_external_match_id), '') is null then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_EXTERNAL_MATCH_ID_REQUIRED';
  end if;

  if p_provider_updated_at is null then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_PROVIDER_UPDATED_AT_REQUIRED';
  end if;

  if p_payload_hash is null
     or p_payload_hash !~ '^[0-9a-f]{64}$' then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_PAYLOAD_HASH_INVALID';
  end if;

  insert into public.live_match_update_receipts (
    provider_id,
    external_match_id,
    match_id,
    provider_updated_at,
    payload_hash,
    normalized_payload,
    meaningful_change,
    change_type,
    processing_status,
    correlation_id,
    processed_at
  )
  values (
    v_provider_id,
    btrim(p_external_match_id),
    p_match_id,
    p_provider_updated_at,
    p_payload_hash,
    coalesce(p_normalized_payload, '{}'::jsonb),
    p_meaningful_change,
    p_change_type,
    case
      when p_meaningful_change is false then 'processed'
      else 'accepted'
    end,
    coalesce(p_correlation_id, gen_random_uuid()),
    case
      when p_meaningful_change is false then clock_timestamp()
      else null
    end
  )
  on conflict (
    provider_id,
    external_match_id,
    provider_updated_at,
    payload_hash
  )
  do nothing
  returning *
  into v_receipt;

  if found then
    return query
    select
      v_receipt.id,
      true,
      v_receipt.processing_status,
      v_receipt.meaningful_change,
      v_receipt.change_type,
      v_receipt.correlation_id;
    return;
  end if;

  select r.*
  into v_receipt
  from public.live_match_update_receipts r
  where r.provider_id = v_provider_id
    and r.external_match_id = btrim(p_external_match_id)
    and r.provider_updated_at = p_provider_updated_at
    and r.payload_hash = p_payload_hash;

  return query
  select
    v_receipt.id,
    false,
    'duplicate'::text,
    v_receipt.meaningful_change,
    v_receipt.change_type,
    v_receipt.correlation_id;
end;
$function$;

-- ============================================================================
-- 9. LIVE STATE SNAPSHOT RPCS
-- ============================================================================

create or replace function public.create_live_state_snapshot_rpc(
  p_simulation_id uuid,
  p_live_state jsonb,
  p_timeline_cursor jsonb default '{}'::jsonb,
  p_health jsonb default jsonb_build_object(
    'status', 'healthy',
    'stale', false
  ),
  p_engine_version text default 'live-state-v1',
  p_snapshot_schema_version integer default 1,
  p_correlation_id uuid default null
)
returns table (
  live_state_snapshot_id uuid,
  league_round_id uuid,
  simulation_id uuid,
  live_state_version integer,
  snapshot_status text,
  input_hash text,
  output_hash text,
  snapshot_hash text
)
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
  v_simulation public.round_simulations%rowtype;
  v_existing public.live_state_snapshots%rowtype;
  v_snapshot public.live_state_snapshots%rowtype;
  v_version integer;
  v_generated_at timestamptz := clock_timestamp();
  v_input_manifest jsonb;
  v_manifest jsonb;
  v_input_hash text;
  v_output_hash text;
  v_snapshot_hash text;
begin
  if p_simulation_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_SOURCE_SIMULATION_REQUIRED';
  end if;

  if p_live_state is null or p_live_state = '{}'::jsonb then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_STATE_PAYLOAD_REQUIRED';
  end if;

  if nullif(btrim(p_engine_version), '') is null then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_ENGINE_VERSION_REQUIRED';
  end if;

  select rs.*
  into v_simulation
  from public.round_simulations rs
  where rs.id = p_simulation_id;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_SOURCE_SIMULATION_NOT_FOUND';
  end if;

  if v_simulation.status not in (
       'preview_ready',
       'awaiting_certification',
       'certified'
     )
     or v_simulation.simulation_hash is null
     or not (v_simulation.digital_twin ? 'ui_snapshot') then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_SOURCE_UI_SNAPSHOT_NOT_READY',
      detail = v_simulation.status;
  end if;

  select ls.*
  into v_existing
  from public.live_state_snapshots ls
  where ls.simulation_id = p_simulation_id
    and ls.engine_version = p_engine_version
  limit 1;

  if found then
    return query
    select
      v_existing.id,
      v_existing.league_round_id,
      v_existing.simulation_id,
      v_existing.live_state_version,
      v_existing.status,
      v_existing.input_hash,
      v_existing.output_hash,
      v_existing.snapshot_hash;
    return;
  end if;

  perform pg_advisory_xact_lock(
    hashtext('live-state-version:' || v_simulation.league_round_id::text)
  );

  select coalesce(max(ls.live_state_version), 0) + 1
  into v_version
  from public.live_state_snapshots ls
  where ls.league_round_id = v_simulation.league_round_id;

  v_input_manifest := jsonb_build_object(
    'source_simulation_id', v_simulation.id,
    'source_simulation_version', v_simulation.simulation_version,
    'source_simulation_hash', v_simulation.simulation_hash,
    'ui_snapshot_hash',
      v_simulation.digital_twin #>> '{manifest,ui_snapshot_hash}',
    'engine_version', p_engine_version,
    'snapshot_schema_version', p_snapshot_schema_version,
    'live_state', p_live_state,
    'timeline_cursor', coalesce(p_timeline_cursor, '{}'::jsonb),
    'health', coalesce(
      p_health,
      jsonb_build_object('status', 'healthy', 'stale', false)
    )
  );

  v_input_hash := public.compute_jsonb_sha256(v_input_manifest);
  v_output_hash := public.compute_jsonb_sha256(
    jsonb_build_object(
      'live_state', p_live_state,
      'timeline_cursor', coalesce(p_timeline_cursor, '{}'::jsonb),
      'health', coalesce(
        p_health,
        jsonb_build_object('status', 'healthy', 'stale', false)
      )
    )
  );

  v_manifest := jsonb_build_object(
    'schema_version', p_snapshot_schema_version,
    'engine', 'LiveStateEngine',
    'engine_version', p_engine_version,
    'league_round_id', v_simulation.league_round_id,
    'round_simulation_id', v_simulation.id,
    'round_simulation_version', v_simulation.simulation_version,
    'live_state_version', v_version,
    'ui_snapshot_hash',
      v_simulation.digital_twin #>> '{manifest,ui_snapshot_hash}',
    'preview', v_simulation.preview,
    'generated_at', v_generated_at,
    'input_hash', v_input_hash,
    'output_hash', v_output_hash
  );

  v_snapshot_hash := public.compute_jsonb_sha256(
    jsonb_build_object(
      'manifest', v_manifest,
      'live_state', p_live_state,
      'timeline_cursor', coalesce(p_timeline_cursor, '{}'::jsonb),
      'health', coalesce(
        p_health,
        jsonb_build_object('status', 'healthy', 'stale', false)
      )
    )
  );

  insert into public.live_state_snapshots (
    league_round_id,
    simulation_id,
    live_state_version,
    engine_version,
    snapshot_schema_version,
    status,
    manifest,
    live_state,
    timeline_cursor,
    health,
    input_hash,
    output_hash,
    snapshot_hash,
    correlation_id,
    generated_at
  )
  values (
    v_simulation.league_round_id,
    v_simulation.id,
    v_version,
    p_engine_version,
    p_snapshot_schema_version,
    'ready',
    v_manifest,
    p_live_state,
    coalesce(p_timeline_cursor, '{}'::jsonb),
    coalesce(
      p_health,
      jsonb_build_object('status', 'healthy', 'stale', false)
    ),
    v_input_hash,
    v_output_hash,
    v_snapshot_hash,
    coalesce(p_correlation_id, v_simulation.correlation_id, gen_random_uuid()),
    v_generated_at
  )
  returning *
  into v_snapshot;

  return query
  select
    v_snapshot.id,
    v_snapshot.league_round_id,
    v_snapshot.simulation_id,
    v_snapshot.live_state_version,
    v_snapshot.status,
    v_snapshot.input_hash,
    v_snapshot.output_hash,
    v_snapshot.snapshot_hash;
end;
$function$;

create or replace function public.publish_live_state_snapshot_rpc(
  p_live_state_snapshot_id uuid,
  p_channel text default 'realtime',
  p_metadata jsonb default '{}'::jsonb
)
returns table (
  publication_id uuid,
  live_state_snapshot_id uuid,
  league_round_id uuid,
  simulation_id uuid,
  publication_version integer,
  channel text,
  publication_status text,
  simulation_version integer,
  simulation_hash text,
  published_at timestamptz
)
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
  v_snapshot public.live_state_snapshots%rowtype;
  v_simulation public.round_simulations%rowtype;
  v_existing_publication public.round_simulation_publications%rowtype;
  v_publication public.round_simulation_publications%rowtype;
  v_previous_snapshot_id uuid;
  v_publication_version integer;
  v_published_at timestamptz := clock_timestamp();
begin
  if p_channel not in ('web', 'android', 'internal', 'realtime') then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_PUBLICATION_CHANNEL_INVALID';
  end if;

  select ls.*
  into v_snapshot
  from public.live_state_snapshots ls
  where ls.id = p_live_state_snapshot_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_STATE_SNAPSHOT_NOT_FOUND';
  end if;

  if v_snapshot.status not in ('ready', 'published') then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_STATE_SNAPSHOT_NOT_PUBLISHABLE',
      detail = v_snapshot.status;
  end if;

  select rs.*
  into v_simulation
  from public.round_simulations rs
  where rs.id = v_snapshot.simulation_id;

  if not found
     or v_simulation.status not in (
       'preview_ready',
       'awaiting_certification',
       'certified'
     )
     or not v_simulation.publishable
     or v_simulation.simulation_hash is null then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_SOURCE_SIMULATION_NOT_PUBLISHABLE';
  end if;

  select rsp.*
  into v_existing_publication
  from public.round_simulation_publications rsp
  where rsp.simulation_id = v_simulation.id
    and rsp.channel = p_channel
  limit 1;

  if found then
    return query
    select
      v_existing_publication.id,
      v_snapshot.id,
      v_existing_publication.league_round_id,
      v_existing_publication.simulation_id,
      v_existing_publication.publication_version,
      v_existing_publication.channel,
      v_existing_publication.status,
      v_existing_publication.simulation_version,
      v_existing_publication.simulation_hash,
      v_existing_publication.published_at;
    return;
  end if;

  perform pg_advisory_xact_lock(
    hashtext(
      'live-publication:'
      || v_snapshot.league_round_id::text
      || ':'
      || p_channel
    )
  );

  select
    (rsp.metadata ->> 'live_state_snapshot_id')::uuid
  into v_previous_snapshot_id
  from public.round_simulation_publications rsp
  where rsp.league_round_id = v_snapshot.league_round_id
    and rsp.channel = p_channel
    and rsp.status = 'published'
  limit 1;

  update public.round_simulation_publications as rsp_current
  set
    status = 'superseded',
    superseded_at = v_published_at
  where rsp_current.league_round_id = v_snapshot.league_round_id
    and rsp_current.channel = p_channel
    and rsp_current.status = 'published';

  if v_previous_snapshot_id is not null
     and v_previous_snapshot_id <> v_snapshot.id
     and not exists (
       select 1
       from public.round_simulation_publications rsp
       where rsp.status = 'published'
         and (rsp.metadata ->> 'live_state_snapshot_id')::uuid
           = v_previous_snapshot_id
     ) then
    update public.live_state_snapshots as ls_previous
    set
      status = 'superseded',
      superseded_at = v_published_at
    where ls_previous.id = v_previous_snapshot_id
      and ls_previous.status = 'published';
  end if;

  select coalesce(max(rsp.publication_version), 0) + 1
  into v_publication_version
  from public.round_simulation_publications rsp
  where rsp.league_round_id = v_snapshot.league_round_id
    and rsp.channel = p_channel;

  insert into public.round_simulation_publications (
    simulation_id,
    league_round_id,
    publication_version,
    channel,
    status,
    simulation_version,
    simulation_hash,
    published_at,
    metadata
  )
  values (
    v_simulation.id,
    v_snapshot.league_round_id,
    v_publication_version,
    p_channel,
    'published',
    v_simulation.simulation_version,
    v_simulation.simulation_hash,
    v_published_at,
    coalesce(p_metadata, '{}'::jsonb)
      || jsonb_build_object(
        'live_state_snapshot_id', v_snapshot.id,
        'live_state_version', v_snapshot.live_state_version,
        'live_state_snapshot_hash', v_snapshot.snapshot_hash,
        'live_engine_version', v_snapshot.engine_version
      )
  )
  returning *
  into v_publication;

  update public.live_state_snapshots as ls_current
  set
    status = 'published',
    primary_publication_id = coalesce(
      ls_current.primary_publication_id,
      v_publication.id
    ),
    published_at = coalesce(
      ls_current.published_at,
      v_published_at
    )
  where ls_current.id = v_snapshot.id;

  insert into public.round_simulation_events (
    simulation_id,
    league_round_id,
    calculation_run_id,
    event_type,
    event_version,
    payload,
    correlation_id,
    occurred_at
  )
  values (
    v_simulation.id,
    v_simulation.league_round_id,
    v_simulation.calculation_run_id,
    'SimulationPublished',
    1,
    jsonb_build_object(
      'publication_id', v_publication.id,
      'publication_version', v_publication.publication_version,
      'channel', v_publication.channel,
      'live_state_snapshot_id', v_snapshot.id,
      'live_state_version', v_snapshot.live_state_version
    ),
    v_snapshot.correlation_id,
    v_published_at
  );

  return query
  select
    v_publication.id,
    v_snapshot.id,
    v_publication.league_round_id,
    v_publication.simulation_id,
    v_publication.publication_version,
    v_publication.channel,
    v_publication.status,
    v_publication.simulation_version,
    v_publication.simulation_hash,
    v_publication.published_at;
end;
$function$;

-- ============================================================================
-- 10. AUTHENTICATED RECOVERY QUERIES
-- ============================================================================

create or replace function public.get_latest_live_state_snapshot_rpc(
  p_league_round_id uuid,
  p_channel text default 'realtime'
)
returns table (
  live_state_snapshot_id uuid,
  live_state_version integer,
  snapshot_status text,
  snapshot_hash text,
  simulation_id uuid,
  simulation_version integer,
  simulation_hash text,
  publication_id uuid,
  publication_version integer,
  publication_channel text,
  published_at timestamptz,
  manifest jsonb,
  live_state jsonb,
  timeline_cursor jsonb,
  health jsonb
)
language plpgsql
stable
security definer
set search_path to public, pg_temp
as $function$
declare
  v_user_id uuid;
begin
  v_user_id := auth.uid();

  if v_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not exists (
    select 1
    from public.league_rounds lr
    join public.league_members lm
      on lm.league_id = lr.league_id
    where lr.id = p_league_round_id
      and lm.user_id = v_user_id
      and lm.status = 'active'
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'ACTIVE_LEAGUE_MEMBERSHIP_REQUIRED';
  end if;

  return query
  select
    ls.id,
    ls.live_state_version,
    ls.status,
    ls.snapshot_hash,
    rs.id,
    rs.simulation_version,
    rs.simulation_hash,
    rsp.id,
    rsp.publication_version,
    rsp.channel,
    rsp.published_at,
    ls.manifest,
    ls.live_state,
    ls.timeline_cursor,
    ls.health
  from public.round_simulation_publications rsp
  join public.live_state_snapshots ls
    on ls.id = (rsp.metadata ->> 'live_state_snapshot_id')::uuid
  join public.round_simulations rs
    on rs.id = rsp.simulation_id
  where rsp.league_round_id = p_league_round_id
    and rsp.channel = p_channel
    and rsp.status = 'published'
  order by rsp.publication_version desc
  limit 1;
end;
$function$;

create or replace function public.get_my_live_state_rpc(
  p_league_round_id uuid,
  p_channel text default 'realtime'
)
returns table (
  live_state_snapshot_id uuid,
  live_state_version integer,
  snapshot_status text,
  snapshot_hash text,
  simulation_id uuid,
  simulation_version integer,
  simulation_hash text,
  publication_id uuid,
  publication_version integer,
  published_at timestamptz,
  manifest jsonb,
  round_view jsonb,
  member_view jsonb,
  ui_snapshot jsonb,
  live_state jsonb,
  health jsonb
)
language plpgsql
stable
security definer
set search_path to public, pg_temp
as $function$
declare
  v_user_id uuid;
  v_member_id uuid;
  v_snapshot public.live_state_snapshots%rowtype;
  v_simulation public.round_simulations%rowtype;
  v_publication public.round_simulation_publications%rowtype;
  v_member_view jsonb;
  v_member_ui jsonb;
  v_member_predictions_ui jsonb;
begin
  v_user_id := auth.uid();

  if v_user_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  select lm.id
  into v_member_id
  from public.league_rounds lr
  join public.league_members lm
    on lm.league_id = lr.league_id
  where lr.id = p_league_round_id
    and lm.user_id = v_user_id
    and lm.status = 'active'
  limit 1;

  if v_member_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'ACTIVE_LEAGUE_MEMBERSHIP_REQUIRED';
  end if;

  select rsp.*
  into v_publication
  from public.round_simulation_publications rsp
  where rsp.league_round_id = p_league_round_id
    and rsp.channel = p_channel
    and rsp.status = 'published'
  order by rsp.publication_version desc
  limit 1;

  if not found then
    return;
  end if;

  select ls.*
  into v_snapshot
  from public.live_state_snapshots ls
  where ls.id =
    (v_publication.metadata ->> 'live_state_snapshot_id')::uuid;

  if not found then
    return;
  end if;

  select rs.*
  into v_simulation
  from public.round_simulations rs
  where rs.id = v_snapshot.simulation_id;

  if not found then
    return;
  end if;

  select value
  into v_member_view
  from jsonb_array_elements(
    coalesce(v_simulation.digital_twin -> 'members', '[]'::jsonb)
  ) value
  where value ->> 'league_member_id' = v_member_id::text
  limit 1;

  select value
  into v_member_ui
  from jsonb_array_elements(
    coalesce(
      v_simulation.digital_twin #> '{ui_snapshot,members_ui}',
      '[]'::jsonb
    )
  ) value
  where value ->> 'league_member_id' = v_member_id::text
  limit 1;

  select coalesce(
    jsonb_agg(
      value
      order by (value ->> 'slot_number')::integer
    ),
    '[]'::jsonb
  )
  into v_member_predictions_ui
  from jsonb_array_elements(
    coalesce(
      v_simulation.digital_twin #> '{ui_snapshot,predictions_ui}',
      '[]'::jsonb
    )
  ) value
  where value ->> 'league_member_id' = v_member_id::text;

  return query
  select
    v_snapshot.id,
    v_snapshot.live_state_version,
    v_snapshot.status,
    v_snapshot.snapshot_hash,
    v_simulation.id,
    v_simulation.simulation_version,
    v_simulation.simulation_hash,
    v_publication.id,
    v_publication.publication_version,
    v_publication.published_at,
    v_snapshot.manifest,
    v_simulation.digital_twin -> 'round',
    coalesce(v_member_view, '{}'::jsonb),
    jsonb_build_object(
      'schema_version', coalesce(
        (
          v_simulation.digital_twin #>>
          '{ui_snapshot,schema_version}'
        )::integer,
        1
      ),
      'builder',
        v_simulation.digital_twin #>>
        '{ui_snapshot,builder}',
      'builder_version',
        v_simulation.digital_twin #>>
        '{ui_snapshot,builder_version}',
      'generated_at',
        v_simulation.digital_twin #>
        '{ui_snapshot,generated_at}',
      'round_ui',
        v_simulation.digital_twin #>
        '{ui_snapshot,round_ui}',
      'matches_ui',
        v_simulation.digital_twin #>
        '{ui_snapshot,matches_ui}',
      'member_ui', coalesce(v_member_ui, '{}'::jsonb),
      'predictions_ui', v_member_predictions_ui,
      'modes_ui',
        v_simulation.digital_twin #>
        '{ui_snapshot,modes_ui}',
      'preview', v_simulation.preview
    ),
    v_snapshot.live_state,
    v_snapshot.health;
end;
$function$;

-- ============================================================================
-- 11. TABLE GRANTS
-- ============================================================================

revoke all on table public.live_runtime_jobs from public;
revoke all on table public.live_runtime_jobs from anon;
revoke all on table public.live_runtime_jobs from authenticated;

revoke all on table public.live_match_update_receipts from public;
revoke all on table public.live_match_update_receipts from anon;
revoke all on table public.live_match_update_receipts from authenticated;

revoke all on table public.live_state_snapshots from public;
revoke all on table public.live_state_snapshots from anon;
revoke all on table public.live_state_snapshots from authenticated;

revoke all on table public.live_runtime_dead_letters from public;
revoke all on table public.live_runtime_dead_letters from anon;
revoke all on table public.live_runtime_dead_letters from authenticated;

grant select on table public.live_state_snapshots
to authenticated;

grant select, insert, update, delete
on table public.live_runtime_jobs
to service_role;

grant select, insert
on table public.live_match_update_receipts
to service_role;

grant select, insert, update
on table public.live_state_snapshots
to service_role;

grant select, insert
on table public.live_runtime_dead_letters
to service_role;

-- ============================================================================
-- 12. FUNCTION GRANTS
-- ============================================================================

revoke all on function public.guard_live_runtime_append_only()
from public;
revoke all on function public.guard_live_runtime_append_only()
from anon;
revoke all on function public.guard_live_runtime_append_only()
from authenticated;

revoke all on function public.validate_live_state_snapshot_source()
from public;
revoke all on function public.validate_live_state_snapshot_source()
from anon;
revoke all on function public.validate_live_state_snapshot_source()
from authenticated;

revoke all on function public.guard_live_state_snapshot_update()
from public;
revoke all on function public.guard_live_state_snapshot_update()
from anon;
revoke all on function public.guard_live_state_snapshot_update()
from authenticated;

revoke all on function public.enqueue_live_runtime_job_rpc(
  text,
  text,
  uuid,
  text,
  integer,
  timestamptz,
  jsonb,
  integer,
  uuid,
  uuid
) from public;
revoke all on function public.enqueue_live_runtime_job_rpc(
  text,
  text,
  uuid,
  text,
  integer,
  timestamptz,
  jsonb,
  integer,
  uuid,
  uuid
) from anon;
revoke all on function public.enqueue_live_runtime_job_rpc(
  text,
  text,
  uuid,
  text,
  integer,
  timestamptz,
  jsonb,
  integer,
  uuid,
  uuid
) from authenticated;
grant execute on function public.enqueue_live_runtime_job_rpc(
  text,
  text,
  uuid,
  text,
  integer,
  timestamptz,
  jsonb,
  integer,
  uuid,
  uuid
) to service_role;

revoke all on function public.claim_live_runtime_job_rpc(
  text,
  text[]
) from public;
revoke all on function public.claim_live_runtime_job_rpc(
  text,
  text[]
) from anon;
revoke all on function public.claim_live_runtime_job_rpc(
  text,
  text[]
) from authenticated;
grant execute on function public.claim_live_runtime_job_rpc(
  text,
  text[]
) to service_role;

revoke all on function public.complete_live_runtime_job_rpc(
  uuid,
  text,
  jsonb
) from public;
revoke all on function public.complete_live_runtime_job_rpc(
  uuid,
  text,
  jsonb
) from anon;
revoke all on function public.complete_live_runtime_job_rpc(
  uuid,
  text,
  jsonb
) from authenticated;
grant execute on function public.complete_live_runtime_job_rpc(
  uuid,
  text,
  jsonb
) to service_role;

revoke all on function public.fail_live_runtime_job_rpc(
  uuid,
  text,
  jsonb,
  integer
) from public;
revoke all on function public.fail_live_runtime_job_rpc(
  uuid,
  text,
  jsonb,
  integer
) from anon;
revoke all on function public.fail_live_runtime_job_rpc(
  uuid,
  text,
  jsonb,
  integer
) from authenticated;
grant execute on function public.fail_live_runtime_job_rpc(
  uuid,
  text,
  jsonb,
  integer
) to service_role;

revoke all on function public.register_live_match_update_rpc(
  text,
  text,
  uuid,
  timestamptz,
  text,
  jsonb,
  boolean,
  text,
  uuid
) from public;
revoke all on function public.register_live_match_update_rpc(
  text,
  text,
  uuid,
  timestamptz,
  text,
  jsonb,
  boolean,
  text,
  uuid
) from anon;
revoke all on function public.register_live_match_update_rpc(
  text,
  text,
  uuid,
  timestamptz,
  text,
  jsonb,
  boolean,
  text,
  uuid
) from authenticated;
grant execute on function public.register_live_match_update_rpc(
  text,
  text,
  uuid,
  timestamptz,
  text,
  jsonb,
  boolean,
  text,
  uuid
) to service_role;

revoke all on function public.create_live_state_snapshot_rpc(
  uuid,
  jsonb,
  jsonb,
  jsonb,
  text,
  integer,
  uuid
) from public;
revoke all on function public.create_live_state_snapshot_rpc(
  uuid,
  jsonb,
  jsonb,
  jsonb,
  text,
  integer,
  uuid
) from anon;
revoke all on function public.create_live_state_snapshot_rpc(
  uuid,
  jsonb,
  jsonb,
  jsonb,
  text,
  integer,
  uuid
) from authenticated;
grant execute on function public.create_live_state_snapshot_rpc(
  uuid,
  jsonb,
  jsonb,
  jsonb,
  text,
  integer,
  uuid
) to service_role;

revoke all on function public.publish_live_state_snapshot_rpc(
  uuid,
  text,
  jsonb
) from public;
revoke all on function public.publish_live_state_snapshot_rpc(
  uuid,
  text,
  jsonb
) from anon;
revoke all on function public.publish_live_state_snapshot_rpc(
  uuid,
  text,
  jsonb
) from authenticated;
grant execute on function public.publish_live_state_snapshot_rpc(
  uuid,
  text,
  jsonb
) to service_role;

revoke all on function public.get_latest_live_state_snapshot_rpc(
  uuid,
  text
) from public;
revoke all on function public.get_latest_live_state_snapshot_rpc(
  uuid,
  text
) from anon;
revoke all on function public.get_latest_live_state_snapshot_rpc(
  uuid,
  text
) from service_role;
grant execute on function public.get_latest_live_state_snapshot_rpc(
  uuid,
  text
) to authenticated;

revoke all on function public.get_my_live_state_rpc(
  uuid,
  text
) from public;
revoke all on function public.get_my_live_state_rpc(
  uuid,
  text
) from anon;
revoke all on function public.get_my_live_state_rpc(
  uuid,
  text
) from service_role;
grant execute on function public.get_my_live_state_rpc(
  uuid,
  text
) to authenticated;

-- ============================================================================
-- 13. COMMENTS
-- ============================================================================

comment on table public.live_runtime_jobs is
'Persistent, idempotent and concurrently claimable application-runtime job queue for provider polling, round rebuilds, Live State publication and certification-readiness workflows.';

comment on table public.live_match_update_receipts is
'Append-only deduplication registry for normalized provider Match updates. A receipt records ingestion identity and change classification but never performs score or simulation calculation.';

comment on table public.live_state_snapshots is
'Immutable versioned Live State Snapshot linked to a presentation-ready Round Simulation. Lifecycle metadata may transition through ready, published, superseded, invalidated, failed and certified without mutating the snapshot payload.';

comment on table public.live_runtime_dead_letters is
'Append-only terminal failure registry for Live Runtime jobs that exhausted their retry budget.';

comment on function public.enqueue_live_runtime_job_rpc(
  text,
  text,
  uuid,
  text,
  integer,
  timestamptz,
  jsonb,
  integer,
  uuid,
  uuid
) is
'Creates an idempotent Live Runtime job or returns the existing job with the same idempotency key. Service-role only.';

comment on function public.claim_live_runtime_job_rpc(
  text,
  text[]
) is
'Atomically claims the next eligible Live Runtime job using FOR UPDATE SKIP LOCKED, allowing multiple workers without duplicate execution. Service-role only.';

comment on function public.complete_live_runtime_job_rpc(
  uuid,
  text,
  jsonb
) is
'Completes a Live Runtime job only when it is owned by the requesting worker. Service-role only.';

comment on function public.fail_live_runtime_job_rpc(
  uuid,
  text,
  jsonb,
  integer
) is
'Retries or dead-letters a claimed Live Runtime job according to its attempt budget. Service-role only.';

comment on function public.register_live_match_update_rpc(
  text,
  text,
  uuid,
  timestamptz,
  text,
  jsonb,
  boolean,
  text,
  uuid
) is
'Registers and deduplicates a normalized provider Match update without directly mutating Match State, scoring, simulations or publications. Service-role only.';

comment on function public.create_live_state_snapshot_rpc(
  uuid,
  jsonb,
  jsonb,
  jsonb,
  text,
  integer,
  uuid
) is
'Creates an immutable Live State Snapshot from a completed UI Snapshot Round Simulation, preserving deterministic hashes and monotonic live-state versioning. Service-role only.';

comment on function public.publish_live_state_snapshot_rpc(
  uuid,
  text,
  jsonb
) is
'Publishes a ready Live State Snapshot through the existing round_simulation_publications registry, superseding the previous channel publication atomically. Service-role only.';

comment on function public.get_latest_live_state_snapshot_rpc(
  uuid,
  text
) is
'Returns the authenticated League Member latest published Live State Snapshot for a league round and publication channel.';

comment on function public.get_my_live_state_rpc(
  uuid,
  text
) is
'Returns the authenticated League Member latest published Live State plus shared UI state and only the caller own member and prediction UI rows.';

commit;
