-- FANTAGOL — MATCH RESULT CERTIFICATION ENGINE FOUNDATION
-- Migration 053
--
-- Purpose:
--   1. Maintain the mutable readiness state for every canonical Match.
--   2. Persist immutable, versioned and globally reusable Match Result Certifications.
--   3. Add the certify_match_result Live Runtime job type.
--   4. Expose service-role RPCs for readiness evaluation and atomic certification.
--
-- Ownership boundary:
--   public.matches                         = mutable canonical provider/live aggregate
--   public.live_match_update_receipts      = append-only provider provenance
--   public.official_match_odds_snapshots   = immutable official pre-match odds evidence
--   public.match_certification_states      = mutable certification workflow state
--   public.match_result_certifications     = immutable global sporting truth archive
--
-- This migration intentionally does NOT rewire Prediction Resolution yet.
-- Resolution will consume active Match Result Certifications in the next milestone.

begin;

create extension if not exists pgcrypto;

-- -----------------------------------------------------------------------------
-- 1. LIVE RUNTIME JOB TYPE EXTENSION
-- -----------------------------------------------------------------------------
-- Preserve every value currently admitted by the existing check constraint and
-- append certify_match_result. This avoids duplicating the historical job list.

do $migration$
declare
  v_constraint_name text := 'live_runtime_jobs_type_check';
  v_definition text;
  v_values text;
  v_sql text;
begin
  select pg_get_constraintdef(c.oid)
    into v_definition
  from pg_constraint c
  join pg_class t on t.oid = c.conrelid
  join pg_namespace n on n.oid = t.relnamespace
  where n.nspname = 'public'
    and t.relname = 'live_runtime_jobs'
    and c.conname = v_constraint_name
    and c.contype = 'c';

  if v_definition is null then
    raise exception using
      errcode = 'P0001',
      message = 'LIVE_RUNTIME_JOB_TYPE_CONSTRAINT_NOT_FOUND';
  end if;

  select string_agg(format('%L', x.value), ', ' order by x.value)
    into v_values
  from (
    select distinct m[1] as value
    from regexp_matches(v_definition, '''([^'']+)''', 'g') as m
    union
    select 'certify_match_result'
  ) x;

  execute 'alter table public.live_runtime_jobs drop constraint '
       || quote_ident(v_constraint_name);

  v_sql := 'alter table public.live_runtime_jobs add constraint '
        || quote_ident(v_constraint_name)
        || ' check (job_type in (' || v_values || '))';

  execute v_sql;
end
$migration$;

-- -----------------------------------------------------------------------------
-- 2. MUTABLE MATCH CERTIFICATION WORKFLOW STATE
-- -----------------------------------------------------------------------------

create table if not exists public.match_certification_states (
  match_id uuid primary key
    references public.matches(id)
    on delete cascade,

  state text not null default 'pending',
  source_match_version integer not null,
  observed_match_status text not null,
  observed_home_score integer,
  observed_away_score integer,
  observed_provider_updated_at timestamptz,
  observed_finalised_at timestamptz,

  readiness_evaluated_at timestamptz,
  stable_since timestamptz,
  ready_at timestamptz,
  certification_started_at timestamptz,
  certified_at timestamptz,
  blocked_at timestamptz,

  stability_window_seconds integer not null default 300,
  require_official_odds boolean not null default true,

  blocking_code text,
  blocking_details jsonb not null default '{}'::jsonb,
  readiness_details jsonb not null default '{}'::jsonb,

  active_certification_id uuid,
  last_certification_version integer,

  correlation_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint match_certification_states_state_check
    check (
      state in (
        'pending',
        'not_ready',
        'stabilizing',
        'ready',
        'certifying',
        'certified',
        'blocked',
        'superseded'
      )
    ),

  constraint match_certification_states_source_version_check
    check (source_match_version > 0),

  constraint match_certification_states_scores_check
    check (
      (observed_home_score is null and observed_away_score is null)
      or
      (
        observed_home_score is not null
        and observed_away_score is not null
        and observed_home_score >= 0
        and observed_away_score >= 0
      )
    ),

  constraint match_certification_states_stability_window_check
    check (stability_window_seconds between 0 and 86400),

  constraint match_certification_states_details_check
    check (
      jsonb_typeof(blocking_details) = 'object'
      and jsonb_typeof(readiness_details) = 'object'
    ),

  constraint match_certification_states_blocking_check
    check (
      (state = 'blocked' and blocking_code is not null and blocked_at is not null)
      or
      (state <> 'blocked')
    ),

  constraint match_certification_states_ready_check
    check (
      state not in ('ready', 'certifying', 'certified')
      or ready_at is not null
    ),

  constraint match_certification_states_certifying_check
    check (
      state <> 'certifying'
      or certification_started_at is not null
    ),

  constraint match_certification_states_certified_check
    check (
      state <> 'certified'
      or (
        certified_at is not null
        and active_certification_id is not null
        and last_certification_version is not null
        and last_certification_version > 0
      )
    ),

  constraint match_certification_states_dates_check
    check (
      updated_at >= created_at
      and (readiness_evaluated_at is null or readiness_evaluated_at >= created_at)
      and (stable_since is null or stable_since >= created_at)
      and (ready_at is null or ready_at >= created_at)
      and (certification_started_at is null or certification_started_at >= created_at)
      and (certified_at is null or certified_at >= created_at)
      and (blocked_at is null or blocked_at >= created_at)
    )
);

create index if not exists match_certification_states_state_idx
  on public.match_certification_states(state, updated_at);

create index if not exists match_certification_states_ready_idx
  on public.match_certification_states(ready_at, updated_at)
  where state = 'ready';

create index if not exists match_certification_states_correlation_idx
  on public.match_certification_states(correlation_id)
  where correlation_id is not null;

-- -----------------------------------------------------------------------------
-- 3. IMMUTABLE MATCH RESULT CERTIFICATION ARCHIVE
-- -----------------------------------------------------------------------------

create table if not exists public.match_result_certifications (
  id uuid primary key default gen_random_uuid(),

  match_id uuid not null
    references public.matches(id)
    on delete restrict,

  certification_version integer not null,
  status text not null default 'official',

  source_match_version integer not null,
  source_receipt_id uuid not null
    references public.live_match_update_receipts(id)
    on delete restrict,
  official_odds_snapshot_id uuid
    references public.official_match_odds_snapshots(id)
    on delete restrict,

  match_status text not null,
  home_score integer not null,
  away_score integer not null,
  result_sign text not null,
  over_under_2_5 text not null,
  goal_no_goal text not null,

  provider_id uuid,
  provider_updated_at timestamptz not null,
  provider_payload_hash text not null,
  match_finalised_at timestamptz,
  stability_window_seconds integer not null,
  stable_since timestamptz not null,

  snapshot_schema_version integer not null default 1,
  engine_version text not null default 'match-result-certification-v1',
  policy_version text not null default 'match-result-certification-policy-v1',

  input_snapshot jsonb not null,
  result_snapshot jsonb not null,
  evidence_snapshot jsonb not null,

  input_hash text not null,
  result_hash text not null,
  certification_hash text not null,

  certified_at timestamptz not null default clock_timestamp(),
  certified_by text not null default 'system',
  correlation_id uuid,

  superseded_at timestamptz,
  superseded_by_certification_id uuid
    references public.match_result_certifications(id)
    on delete restrict,
  supersede_reason text,

  created_at timestamptz not null default clock_timestamp(),

  constraint match_result_certifications_version_check
    check (certification_version > 0),

  constraint match_result_certifications_status_check
    check (status in ('official', 'superseded')),

  constraint match_result_certifications_source_version_check
    check (source_match_version > 0),

  constraint match_result_certifications_scores_check
    check (home_score >= 0 and away_score >= 0),

  constraint match_result_certifications_sign_check
    check (result_sign in ('1', 'X', '2')),

  constraint match_result_certifications_ou_check
    check (over_under_2_5 in ('OVER_2_5', 'UNDER_2_5')),

  constraint match_result_certifications_gng_check
    check (goal_no_goal in ('GOAL', 'NO_GOAL')),

  constraint match_result_certifications_stability_check
    check (
      stability_window_seconds between 0 and 86400
      and certified_at >= stable_since
    ),

  constraint match_result_certifications_schema_check
    check (snapshot_schema_version > 0),

  constraint match_result_certifications_engine_check
    check (btrim(engine_version) <> '' and btrim(policy_version) <> ''),

  constraint match_result_certifications_snapshot_check
    check (
      jsonb_typeof(input_snapshot) = 'object'
      and jsonb_typeof(result_snapshot) = 'object'
      and jsonb_typeof(evidence_snapshot) = 'object'
    ),

  constraint match_result_certifications_hashes_check
    check (
      input_hash ~ '^[0-9a-f]{64}$'
      and result_hash ~ '^[0-9a-f]{64}$'
      and certification_hash ~ '^[0-9a-f]{64}$'
      and provider_payload_hash ~ '^[0-9a-f]{64}$'
    ),

  constraint match_result_certifications_certified_by_check
    check (btrim(certified_by) <> ''),

  constraint match_result_certifications_supersede_check
    check (
      (
        status = 'official'
        and superseded_at is null
        and superseded_by_certification_id is null
        and supersede_reason is null
      )
      or
      (
        status = 'superseded'
        and superseded_at is not null
        and supersede_reason is not null
        and btrim(supersede_reason) <> ''
      )
    ),

  constraint match_result_certifications_dates_check
    check (
      provider_updated_at <= certified_at + interval '5 minutes'
      and stable_since <= certified_at
      and created_at >= certified_at - interval '5 minutes'
      and (superseded_at is null or superseded_at >= certified_at)
    ),

  constraint match_result_certifications_match_version_unique
    unique (match_id, certification_version),

  constraint match_result_certifications_source_unique
    unique (match_id, source_match_version, certification_hash),

  constraint match_result_certifications_hash_unique
    unique (certification_hash)
);

alter table public.match_certification_states
  drop constraint if exists match_certification_states_active_certification_fk;

alter table public.match_certification_states
  add constraint match_certification_states_active_certification_fk
  foreign key (active_certification_id)
  references public.match_result_certifications(id)
  on delete restrict;

create unique index if not exists match_result_certifications_one_active_idx
  on public.match_result_certifications(match_id)
  where status = 'official';

create index if not exists match_result_certifications_match_idx
  on public.match_result_certifications(match_id, certification_version desc);

create index if not exists match_result_certifications_receipt_idx
  on public.match_result_certifications(source_receipt_id);

create index if not exists match_result_certifications_odds_idx
  on public.match_result_certifications(official_odds_snapshot_id)
  where official_odds_snapshot_id is not null;

create index if not exists match_result_certifications_correlation_idx
  on public.match_result_certifications(correlation_id)
  where correlation_id is not null;

-- -----------------------------------------------------------------------------
-- 4. WORKFLOW AND IMMUTABILITY GUARDS
-- -----------------------------------------------------------------------------

create or replace function public.set_match_certification_state_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at := clock_timestamp();
  return new;
end;
$$;

drop trigger if exists set_match_certification_states_updated_at
  on public.match_certification_states;

create trigger set_match_certification_states_updated_at
before update on public.match_certification_states
for each row execute function public.set_match_certification_state_updated_at();

create or replace function public.guard_match_result_certification_update()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    raise exception using
      errcode = 'P0001',
      message = 'MATCH_RESULT_CERTIFICATION_IMMUTABLE';
  end if;

  if old.status = 'superseded'
     and new.status = 'superseded'
     and old.superseded_by_certification_id is null
     and new.superseded_by_certification_id is not null
     and new.id = old.id
     and new.match_id = old.match_id
     and new.certification_version = old.certification_version
     and new.source_match_version = old.source_match_version
     and new.source_receipt_id = old.source_receipt_id
     and new.official_odds_snapshot_id is not distinct from old.official_odds_snapshot_id
     and new.match_status = old.match_status
     and new.home_score = old.home_score
     and new.away_score = old.away_score
     and new.result_sign = old.result_sign
     and new.over_under_2_5 = old.over_under_2_5
     and new.goal_no_goal = old.goal_no_goal
     and new.provider_id is not distinct from old.provider_id
     and new.provider_updated_at = old.provider_updated_at
     and new.provider_payload_hash = old.provider_payload_hash
     and new.match_finalised_at is not distinct from old.match_finalised_at
     and new.stability_window_seconds = old.stability_window_seconds
     and new.stable_since = old.stable_since
     and new.snapshot_schema_version = old.snapshot_schema_version
     and new.engine_version = old.engine_version
     and new.policy_version = old.policy_version
     and new.input_snapshot = old.input_snapshot
     and new.result_snapshot = old.result_snapshot
     and new.evidence_snapshot = old.evidence_snapshot
     and new.input_hash = old.input_hash
     and new.result_hash = old.result_hash
     and new.certification_hash = old.certification_hash
     and new.certified_at = old.certified_at
     and new.certified_by = old.certified_by
     and new.correlation_id is not distinct from old.correlation_id
     and new.superseded_at = old.superseded_at
     and new.supersede_reason = old.supersede_reason
     and new.created_at = old.created_at then
    return new;
  end if;

  if old.status = 'official'
     and new.status = 'superseded'
     and new.superseded_at is not null
     and new.supersede_reason is not null
     and btrim(new.supersede_reason) <> ''
     and new.id = old.id
     and new.match_id = old.match_id
     and new.certification_version = old.certification_version
     and new.source_match_version = old.source_match_version
     and new.source_receipt_id = old.source_receipt_id
     and new.official_odds_snapshot_id is not distinct from old.official_odds_snapshot_id
     and new.match_status = old.match_status
     and new.home_score = old.home_score
     and new.away_score = old.away_score
     and new.result_sign = old.result_sign
     and new.over_under_2_5 = old.over_under_2_5
     and new.goal_no_goal = old.goal_no_goal
     and new.provider_id is not distinct from old.provider_id
     and new.provider_updated_at = old.provider_updated_at
     and new.provider_payload_hash = old.provider_payload_hash
     and new.match_finalised_at is not distinct from old.match_finalised_at
     and new.stability_window_seconds = old.stability_window_seconds
     and new.stable_since = old.stable_since
     and new.snapshot_schema_version = old.snapshot_schema_version
     and new.engine_version = old.engine_version
     and new.policy_version = old.policy_version
     and new.input_snapshot = old.input_snapshot
     and new.result_snapshot = old.result_snapshot
     and new.evidence_snapshot = old.evidence_snapshot
     and new.input_hash = old.input_hash
     and new.result_hash = old.result_hash
     and new.certification_hash = old.certification_hash
     and new.certified_at = old.certified_at
     and new.certified_by = old.certified_by
     and new.correlation_id is not distinct from old.correlation_id
     and new.created_at = old.created_at then
    return new;
  end if;

  raise exception using
    errcode = 'P0001',
    message = 'MATCH_RESULT_CERTIFICATION_IMMUTABLE';
end;
$$;

drop trigger if exists match_result_certifications_guard
  on public.match_result_certifications;

create trigger match_result_certifications_guard
before update or delete on public.match_result_certifications
for each row execute function public.guard_match_result_certification_update();

-- -----------------------------------------------------------------------------
-- 5. READINESS EVALUATION RPC
-- -----------------------------------------------------------------------------

create or replace function public.evaluate_match_certification_readiness_rpc(
  p_match_id uuid,
  p_stability_window_seconds integer default 300,
  p_require_official_odds boolean default true,
  p_correlation_id uuid default null
)
returns table (
  match_id uuid,
  certification_state text,
  source_match_version integer,
  is_ready boolean,
  stable_since timestamptz,
  ready_at timestamptz,
  blocking_code text,
  active_certification_id uuid,
  details jsonb
)
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_match public.matches%rowtype;
  v_state public.match_certification_states%rowtype;
  v_receipt public.live_match_update_receipts%rowtype;
  v_odds public.official_match_odds_snapshots%rowtype;
  v_now timestamptz := clock_timestamp();
  v_stable_since timestamptz;
  v_ready_at timestamptz;
  v_state_name text;
  v_blocking_code text;
  v_blocking_details jsonb := '{}'::jsonb;
  v_details jsonb;
  v_is_ready boolean := false;
begin
  if p_match_id is null then
    raise exception using errcode = '22004', message = 'MATCH_ID_REQUIRED';
  end if;

  if p_stability_window_seconds is null
     or p_stability_window_seconds < 0
     or p_stability_window_seconds > 86400 then
    raise exception using errcode = '22023', message = 'INVALID_STABILITY_WINDOW';
  end if;

  select m.*
    into v_match
  from public.matches m
  where m.id = p_match_id
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'MATCH_NOT_FOUND';
  end if;

  select r.*
    into v_receipt
  from public.live_match_update_receipts r
  where r.match_id = p_match_id
    and r.provider_updated_at = v_match.provider_updated_at
  order by r.received_at desc, r.created_at desc, r.id desc
  limit 1;

  select o.*
    into v_odds
  from public.official_match_odds_snapshots o
  where o.match_id = p_match_id
  order by o.frozen_at desc, o.created_at desc, o.id desc
  limit 1;

  select s.*
    into v_state
  from public.match_certification_states s
  where s.match_id = p_match_id
  for update;

  if not found then
    insert into public.match_certification_states (
      match_id,
      state,
      source_match_version,
      observed_match_status,
      observed_home_score,
      observed_away_score,
      observed_provider_updated_at,
      observed_finalised_at,
      stability_window_seconds,
      require_official_odds,
      correlation_id
    ) values (
      p_match_id,
      'pending',
      v_match.version,
      v_match.status,
      v_match.home_score,
      v_match.away_score,
      v_match.provider_updated_at,
      v_match.finalised_at,
      p_stability_window_seconds,
      p_require_official_odds,
      p_correlation_id
    )
    returning * into v_state;
  end if;

  -- A new Match version restarts stability unless an already active certificate
  -- proves this exact source version has already been certified.
  if v_state.source_match_version <> v_match.version
     or v_state.observed_match_status is distinct from v_match.status
     or v_state.observed_home_score is distinct from v_match.home_score
     or v_state.observed_away_score is distinct from v_match.away_score
     or v_state.observed_provider_updated_at is distinct from v_match.provider_updated_at then
    v_state.stable_since := null;
    v_state.ready_at := null;
    v_state.certification_started_at := null;
    v_state.blocked_at := null;
    v_state.blocking_code := null;
    v_state.blocking_details := '{}'::jsonb;
  end if;

  if lower(coalesce(v_match.status, '')) not in ('finished', 'awarded') then
    v_state_name := 'not_ready';
    v_blocking_code := 'MATCH_NOT_FINAL';
    v_blocking_details := jsonb_build_object('match_status', v_match.status);

  elsif v_match.home_score is null or v_match.away_score is null then
    v_state_name := 'blocked';
    v_blocking_code := 'FINAL_SCORE_MISSING';
    v_blocking_details := jsonb_build_object(
      'home_score', v_match.home_score,
      'away_score', v_match.away_score
    );

  elsif v_match.home_score < 0 or v_match.away_score < 0 then
    v_state_name := 'blocked';
    v_blocking_code := 'FINAL_SCORE_INVALID';

  elsif v_match.provider_updated_at is null then
    v_state_name := 'blocked';
    v_blocking_code := 'PROVIDER_UPDATED_AT_MISSING';

  elsif v_receipt.id is null then
    v_state_name := 'blocked';
    v_blocking_code := 'MATCH_UPDATE_RECEIPT_MISSING';
    v_blocking_details := jsonb_build_object(
      'provider_updated_at', v_match.provider_updated_at,
      'source_match_version', v_match.version
    );

  elsif p_require_official_odds and v_odds.id is null then
    v_state_name := 'not_ready';
    v_blocking_code := 'OFFICIAL_ODDS_SNAPSHOT_MISSING';

  else
    v_stable_since := coalesce(
      case
        when v_state.source_match_version = v_match.version
         and v_state.observed_match_status is not distinct from v_match.status
         and v_state.observed_home_score is not distinct from v_match.home_score
         and v_state.observed_away_score is not distinct from v_match.away_score
         and v_state.observed_provider_updated_at is not distinct from v_match.provider_updated_at
        then v_state.stable_since
      end,
      greatest(
        coalesce(v_match.finalised_at, '-infinity'::timestamptz),
        coalesce(v_match.provider_updated_at, '-infinity'::timestamptz),
        v_now
      )
    );

    v_ready_at := v_stable_since + make_interval(secs => p_stability_window_seconds);

    if v_now < v_ready_at then
      v_state_name := 'stabilizing';
      v_blocking_code := 'STABILITY_WINDOW_OPEN';
      v_blocking_details := jsonb_build_object(
        'seconds_remaining', greatest(
          0,
          ceil(extract(epoch from (v_ready_at - v_now)))::integer
        )
      );
    else
      v_state_name := 'ready';
      v_blocking_code := null;
      v_blocking_details := '{}'::jsonb;
      v_is_ready := true;
    end if;
  end if;

  if v_state_name = 'blocked' then
    v_state.blocked_at := coalesce(v_state.blocked_at, v_now);
  else
    v_state.blocked_at := null;
  end if;

  if v_state_name not in ('stabilizing', 'ready') then
    v_stable_since := null;
    v_ready_at := null;
  end if;

  v_details := jsonb_build_object(
    'evaluated_at', v_now,
    'match_status', v_match.status,
    'home_score', v_match.home_score,
    'away_score', v_match.away_score,
    'provider_updated_at', v_match.provider_updated_at,
    'finalised_at', v_match.finalised_at,
    'source_match_version', v_match.version,
    'source_receipt_id', v_receipt.id,
    'official_odds_snapshot_id', v_odds.id,
    'official_odds_required', p_require_official_odds,
    'stability_window_seconds', p_stability_window_seconds,
    'stable_since', v_stable_since,
    'ready_at', v_ready_at
  );

  update public.match_certification_states s
  set state = v_state_name,
      source_match_version = v_match.version,
      observed_match_status = v_match.status,
      observed_home_score = v_match.home_score,
      observed_away_score = v_match.away_score,
      observed_provider_updated_at = v_match.provider_updated_at,
      observed_finalised_at = v_match.finalised_at,
      readiness_evaluated_at = v_now,
      stable_since = v_stable_since,
      ready_at = v_ready_at,
      certification_started_at = case
        when v_state_name = 'certifying' then s.certification_started_at
        else null
      end,
      blocked_at = case when v_state_name = 'blocked' then v_state.blocked_at else null end,
      stability_window_seconds = p_stability_window_seconds,
      require_official_odds = p_require_official_odds,
      blocking_code = v_blocking_code,
      blocking_details = v_blocking_details,
      readiness_details = v_details,
      correlation_id = coalesce(p_correlation_id, s.correlation_id)
  where s.match_id = p_match_id
  returning s.* into v_state;

  return query
  select
    p_match_id,
    v_state.state,
    v_state.source_match_version,
    v_is_ready,
    v_state.stable_since,
    v_state.ready_at,
    v_state.blocking_code,
    v_state.active_certification_id,
    v_state.readiness_details || jsonb_build_object(
      'blocking_details', v_state.blocking_details
    );
end;
$$;

-- -----------------------------------------------------------------------------
-- 6. ATOMIC MATCH RESULT CERTIFICATION RPC
-- -----------------------------------------------------------------------------

create or replace function public.certify_match_result_rpc(
  p_match_id uuid,
  p_stability_window_seconds integer default 300,
  p_require_official_odds boolean default true,
  p_engine_version text default 'match-result-certification-v1',
  p_policy_version text default 'match-result-certification-policy-v1',
  p_certified_by text default 'system',
  p_correlation_id uuid default null
)
returns table (
  certification_id uuid,
  match_id uuid,
  certification_version integer,
  certification_status text,
  certification_hash text,
  source_match_version integer,
  created boolean,
  superseded_certification_id uuid
)
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_readiness record;
  v_match public.matches%rowtype;
  v_state public.match_certification_states%rowtype;
  v_receipt public.live_match_update_receipts%rowtype;
  v_odds public.official_match_odds_snapshots%rowtype;
  v_existing public.match_result_certifications%rowtype;
  v_new public.match_result_certifications%rowtype;
  v_superseded_id uuid;
  v_next_version integer;
  v_input_snapshot jsonb;
  v_result_snapshot jsonb;
  v_evidence_snapshot jsonb;
  v_input_hash text;
  v_result_hash text;
  v_certification_hash text;
begin
  if p_match_id is null then
    raise exception using errcode = '22004', message = 'MATCH_ID_REQUIRED';
  end if;

  if btrim(coalesce(p_engine_version, '')) = '' then
    raise exception using errcode = '22023', message = 'ENGINE_VERSION_REQUIRED';
  end if;

  if btrim(coalesce(p_policy_version, '')) = '' then
    raise exception using errcode = '22023', message = 'POLICY_VERSION_REQUIRED';
  end if;

  if btrim(coalesce(p_certified_by, '')) = '' then
    raise exception using errcode = '22023', message = 'CERTIFIED_BY_REQUIRED';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_match_id::text, 53001));

  select *
    into v_readiness
  from public.evaluate_match_certification_readiness_rpc(
    p_match_id,
    p_stability_window_seconds,
    p_require_official_odds,
    p_correlation_id
  );

  if not coalesce(v_readiness.is_ready, false) then
    raise exception using
      errcode = 'P0001',
      message = 'MATCH_NOT_READY_FOR_CERTIFICATION',
      detail = coalesce(v_readiness.blocking_code, 'UNKNOWN');
  end if;

  select m.* into v_match
  from public.matches m
  where m.id = p_match_id
  for update;

  select s.* into v_state
  from public.match_certification_states s
  where s.match_id = p_match_id
  for update;

  select r.* into v_receipt
  from public.live_match_update_receipts r
  where r.match_id = p_match_id
    and r.provider_updated_at = v_match.provider_updated_at
  order by r.received_at desc, r.created_at desc, r.id desc
  limit 1;

  select o.* into v_odds
  from public.official_match_odds_snapshots o
  where o.match_id = p_match_id
  order by o.frozen_at desc, o.created_at desc, o.id desc
  limit 1;

  if v_receipt.id is null then
    raise exception using errcode = 'P0001', message = 'MATCH_UPDATE_RECEIPT_MISSING';
  end if;

  if p_require_official_odds and v_odds.id is null then
    raise exception using errcode = 'P0001', message = 'OFFICIAL_ODDS_SNAPSHOT_MISSING';
  end if;

  update public.match_certification_states s
  set state = 'certifying',
      certification_started_at = clock_timestamp(),
      blocking_code = null,
      blocking_details = '{}'::jsonb,
      correlation_id = coalesce(p_correlation_id, s.correlation_id)
  where s.match_id = p_match_id
  returning s.* into v_state;

  v_input_snapshot := jsonb_build_object(
    'schema_version', 1,
    'match_id', v_match.id,
    'source_match_version', v_match.version,
    'match_status', v_match.status,
    'home_score', v_match.home_score,
    'away_score', v_match.away_score,
    'provider_updated_at', v_match.provider_updated_at,
    'match_finalised_at', v_match.finalised_at,
    'source_receipt_id', v_receipt.id,
    'provider_id', v_receipt.provider_id,
    'provider_payload_hash', v_receipt.payload_hash,
    'official_odds_snapshot_id', v_odds.id,
    'official_odds_hash', v_odds.official_hash,
    'stability_window_seconds', p_stability_window_seconds,
    'stable_since', v_state.stable_since,
    'engine_version', p_engine_version,
    'policy_version', p_policy_version
  );

  v_result_snapshot := jsonb_build_object(
    'match_id', v_match.id,
    'match_status', v_match.status,
    'home_score', v_match.home_score,
    'away_score', v_match.away_score,
    'result_sign', public.derive_score_sign(v_match.home_score, v_match.away_score),
    'over_under_2_5', public.derive_over_under_2_5(v_match.home_score, v_match.away_score),
    'goal_no_goal', public.derive_goal_no_goal(v_match.home_score, v_match.away_score)
  );

  v_evidence_snapshot := jsonb_build_object(
    'receipt', jsonb_build_object(
      'id', v_receipt.id,
      'provider_id', v_receipt.provider_id,
      'external_match_id', v_receipt.external_match_id,
      'provider_updated_at', v_receipt.provider_updated_at,
      'received_at', v_receipt.received_at,
      'payload_hash', v_receipt.payload_hash,
      'change_type', v_receipt.change_type
    ),
    'official_odds', case
      when v_odds.id is null then null
      else jsonb_build_object(
        'id', v_odds.id,
        'odds_market_snapshot_id', v_odds.odds_market_snapshot_id,
        'frozen_at', v_odds.frozen_at,
        'freeze_reason', v_odds.freeze_reason,
        'policy_version', v_odds.policy_version,
        'official_hash', v_odds.official_hash
      )
    end,
    'readiness', v_state.readiness_details
  );

  v_input_hash := public.compute_jsonb_sha256(v_input_snapshot);
  v_result_hash := public.compute_jsonb_sha256(v_result_snapshot);
  v_certification_hash := public.compute_jsonb_sha256(
    jsonb_build_object(
      'match_id', v_match.id,
      'source_match_version', v_match.version,
      'input_hash', v_input_hash,
      'result_hash', v_result_hash,
      'engine_version', p_engine_version,
      'policy_version', p_policy_version,
      'schema_version', 1
    )
  );

  select c.* into v_existing
  from public.match_result_certifications c
  where c.match_id = p_match_id
    and c.status = 'official'
  for update;

  if found
     and v_existing.source_match_version = v_match.version
     and v_existing.certification_hash = v_certification_hash then
    update public.match_certification_states s
    set state = 'certified',
        active_certification_id = v_existing.id,
        last_certification_version = v_existing.certification_version,
        certified_at = v_existing.certified_at,
        certification_started_at = null,
        blocking_code = null,
        blocking_details = '{}'::jsonb
    where s.match_id = p_match_id;

    return query
    select
      v_existing.id,
      v_existing.match_id,
      v_existing.certification_version,
      v_existing.status,
      v_existing.certification_hash,
      v_existing.source_match_version,
      false,
      null::uuid;
    return;
  end if;

  if found then
    v_superseded_id := v_existing.id;

    update public.match_result_certifications c
    set status = 'superseded',
        superseded_at = clock_timestamp(),
        supersede_reason = 'new_canonical_match_version_certified'
    where c.id = v_existing.id;
  end if;

  select coalesce(max(c.certification_version), 0) + 1
    into v_next_version
  from public.match_result_certifications c
  where c.match_id = p_match_id;

  insert into public.match_result_certifications (
    match_id,
    certification_version,
    status,
    source_match_version,
    source_receipt_id,
    official_odds_snapshot_id,
    match_status,
    home_score,
    away_score,
    result_sign,
    over_under_2_5,
    goal_no_goal,
    provider_id,
    provider_updated_at,
    provider_payload_hash,
    match_finalised_at,
    stability_window_seconds,
    stable_since,
    snapshot_schema_version,
    engine_version,
    policy_version,
    input_snapshot,
    result_snapshot,
    evidence_snapshot,
    input_hash,
    result_hash,
    certification_hash,
    certified_by,
    correlation_id
  ) values (
    p_match_id,
    v_next_version,
    'official',
    v_match.version,
    v_receipt.id,
    v_odds.id,
    v_match.status,
    v_match.home_score,
    v_match.away_score,
    public.derive_score_sign(v_match.home_score, v_match.away_score),
    public.derive_over_under_2_5(v_match.home_score, v_match.away_score),
    public.derive_goal_no_goal(v_match.home_score, v_match.away_score),
    v_receipt.provider_id,
    v_match.provider_updated_at,
    v_receipt.payload_hash,
    v_match.finalised_at,
    p_stability_window_seconds,
    v_state.stable_since,
    1,
    p_engine_version,
    p_policy_version,
    v_input_snapshot,
    v_result_snapshot,
    v_evidence_snapshot,
    v_input_hash,
    v_result_hash,
    v_certification_hash,
    p_certified_by,
    p_correlation_id
  )
  returning * into v_new;

  if v_superseded_id is not null then
    update public.match_result_certifications c
    set superseded_by_certification_id = v_new.id
    where c.id = v_superseded_id;
  end if;

  update public.match_certification_states s
  set state = 'certified',
      active_certification_id = v_new.id,
      last_certification_version = v_new.certification_version,
      certified_at = v_new.certified_at,
      certification_started_at = null,
      blocking_code = null,
      blocking_details = '{}'::jsonb,
      readiness_details = s.readiness_details || jsonb_build_object(
        'certification_id', v_new.id,
        'certification_version', v_new.certification_version,
        'certification_hash', v_new.certification_hash
      )
  where s.match_id = p_match_id;

  return query
  select
    v_new.id,
    v_new.match_id,
    v_new.certification_version,
    v_new.status,
    v_new.certification_hash,
    v_new.source_match_version,
    true,
    v_superseded_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- 7. EXPLICIT SUPERSEDE RPC
-- -----------------------------------------------------------------------------

create or replace function public.supersede_match_result_certification_rpc(
  p_certification_id uuid,
  p_reason text,
  p_correlation_id uuid default null
)
returns table (
  certification_id uuid,
  match_id uuid,
  certification_version integer,
  certification_status text,
  superseded_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_cert public.match_result_certifications%rowtype;
begin
  if p_certification_id is null then
    raise exception using errcode = '22004', message = 'CERTIFICATION_ID_REQUIRED';
  end if;

  if btrim(coalesce(p_reason, '')) = '' then
    raise exception using errcode = '22023', message = 'SUPERSEDE_REASON_REQUIRED';
  end if;

  select c.* into v_cert
  from public.match_result_certifications c
  where c.id = p_certification_id
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'MATCH_RESULT_CERTIFICATION_NOT_FOUND';
  end if;

  if v_cert.status = 'official' then
    update public.match_result_certifications c
    set status = 'superseded',
        superseded_at = clock_timestamp(),
        supersede_reason = p_reason
    where c.id = p_certification_id
    returning c.* into v_cert;

    update public.match_certification_states s
    set state = 'superseded',
        active_certification_id = null,
        certified_at = null,
        blocking_code = 'ACTIVE_CERTIFICATION_SUPERSEDED',
        blocking_details = jsonb_build_object(
          'certification_id', v_cert.id,
          'reason', p_reason
        ),
        correlation_id = coalesce(p_correlation_id, s.correlation_id)
    where s.match_id = v_cert.match_id
      and s.active_certification_id = v_cert.id;
  end if;

  return query
  select
    v_cert.id,
    v_cert.match_id,
    v_cert.certification_version,
    v_cert.status,
    v_cert.superseded_at;
end;
$$;

-- -----------------------------------------------------------------------------
-- 8. QUERY RPC
-- -----------------------------------------------------------------------------

create or replace function public.get_active_match_result_certification_rpc(
  p_match_id uuid
)
returns table (
  certification_id uuid,
  match_id uuid,
  certification_version integer,
  source_match_version integer,
  match_status text,
  home_score integer,
  away_score integer,
  result_sign text,
  over_under_2_5 text,
  goal_no_goal text,
  provider_updated_at timestamptz,
  official_odds_snapshot_id uuid,
  input_hash text,
  result_hash text,
  certification_hash text,
  certified_at timestamptz,
  engine_version text,
  policy_version text
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    c.id,
    c.match_id,
    c.certification_version,
    c.source_match_version,
    c.match_status,
    c.home_score,
    c.away_score,
    c.result_sign,
    c.over_under_2_5,
    c.goal_no_goal,
    c.provider_updated_at,
    c.official_odds_snapshot_id,
    c.input_hash,
    c.result_hash,
    c.certification_hash,
    c.certified_at,
    c.engine_version,
    c.policy_version
  from public.match_result_certifications c
  where c.match_id = p_match_id
    and c.status = 'official'
  order by c.certification_version desc
  limit 1;
$$;

-- -----------------------------------------------------------------------------
-- 9. SECURITY
-- -----------------------------------------------------------------------------

alter table public.match_certification_states enable row level security;
alter table public.match_result_certifications enable row level security;

revoke all on table public.match_certification_states from public;
revoke all on table public.match_certification_states from anon;
revoke all on table public.match_certification_states from authenticated;

revoke all on table public.match_result_certifications from public;
revoke all on table public.match_result_certifications from anon;
revoke all on table public.match_result_certifications from authenticated;

grant all on table public.match_certification_states to service_role;
grant all on table public.match_result_certifications to service_role;

revoke all on function public.evaluate_match_certification_readiness_rpc(
  uuid, integer, boolean, uuid
) from public, anon, authenticated;

grant execute on function public.evaluate_match_certification_readiness_rpc(
  uuid, integer, boolean, uuid
) to service_role;

revoke all on function public.certify_match_result_rpc(
  uuid, integer, boolean, text, text, text, uuid
) from public, anon, authenticated;

grant execute on function public.certify_match_result_rpc(
  uuid, integer, boolean, text, text, text, uuid
) to service_role;

revoke all on function public.supersede_match_result_certification_rpc(
  uuid, text, uuid
) from public, anon, authenticated;

grant execute on function public.supersede_match_result_certification_rpc(
  uuid, text, uuid
) to service_role;

revoke all on function public.get_active_match_result_certification_rpc(uuid)
  from public, anon, authenticated;

grant execute on function public.get_active_match_result_certification_rpc(uuid)
  to service_role;

-- -----------------------------------------------------------------------------
-- 10. DOCUMENTATION
-- -----------------------------------------------------------------------------

comment on table public.match_certification_states is
'Mutable workflow state for global Match Result Certification. It observes the canonical public.matches version and records readiness, stability, blocking and active certification metadata.';

comment on table public.match_result_certifications is
'Immutable, versioned and globally reusable certification of one canonical Match result. This archive is upstream of Prediction Resolution and separate from per-League Round Certification.';

comment on function public.evaluate_match_certification_readiness_rpc(
  uuid, integer, boolean, uuid
) is
'Evaluates and persists Match Result Certification readiness from canonical Match state, matching provider receipt, official odds evidence and a configurable stability window. Service-role only.';

comment on function public.certify_match_result_rpc(
  uuid, integer, boolean, text, text, text, uuid
) is
'Atomically creates an immutable Match Result Certification after a fresh readiness evaluation. Idempotent for the same canonical Match version and deterministic certification hash. Service-role only.';

comment on function public.supersede_match_result_certification_rpc(
  uuid, text, uuid
) is
'Explicitly supersedes one active Match Result Certification while preserving all immutable sporting evidence. Service-role only.';

comment on function public.get_active_match_result_certification_rpc(uuid) is
'Returns the single active official Match Result Certification for one Match. Service-role only.';

commit;
