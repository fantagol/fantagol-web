begin;

-- ============================================================================
-- FANTAGOL
-- Migration 217
-- Market Intelligence Persistence Activation
--
-- Extends Migration 216 without duplicating its canonical columns.
--
-- Existing canonical mappings preserved:
--   expected_home_goals -> BM lambda_home
--   expected_away_goals -> BM lambda_away
--   confidence_score    -> BM final_confidence
--   output_payload      -> score matrix / Exact distribution / rich output
--
-- New persistence:
--   capture/source identity
--   U/O 2.5
--   G/NG
--   market confidence
--   model loss
--   granular temporal signal movements
--   latest/history/trend internal read models
-- ============================================================================

-- ============================================================================
-- 1. ROUND SNAPSHOT CAPTURE IDENTITY
-- ============================================================================

alter table public.market_intelligence_snapshots
  add column if not exists captured_at timestamptz,
  add column if not exists snapshot_source text;

alter table public.market_intelligence_snapshots
  drop constraint if exists market_intelligence_snapshots_source_check;

alter table public.market_intelligence_snapshots
  add constraint market_intelligence_snapshots_source_check
  check (
    snapshot_source is null
    or snapshot_source in ('PACKAGE', 'ADVANCED')
  );

create index if not exists
  market_intelligence_snapshots_capture_idx
on public.market_intelligence_snapshots (
  fantagol_round_id,
  captured_at desc,
  snapshot_version desc
);

-- ============================================================================
-- 2. MATCH SNAPSHOT SECONDARY SIGNALS
--
-- DO NOT duplicate:
--   expected_home_goals
--   expected_away_goals
--   confidence_score
--   output_payload
-- ============================================================================

alter table public.market_intelligence_match_snapshots
  add column if not exists over_25_probability numeric(8,6),
  add column if not exists under_25_probability numeric(8,6),
  add column if not exists goal_probability numeric(8,6),
  add column if not exists no_goal_probability numeric(8,6),
  add column if not exists market_confidence numeric(8,6),
  add column if not exists model_loss numeric(16,12);

alter table public.market_intelligence_match_snapshots
  drop constraint if exists
    market_intelligence_match_secondary_probability_check;

alter table public.market_intelligence_match_snapshots
  add constraint
    market_intelligence_match_secondary_probability_check
  check (
    (over_25_probability is null or over_25_probability between 0 and 1)
    and
    (under_25_probability is null or under_25_probability between 0 and 1)
    and
    (goal_probability is null or goal_probability between 0 and 1)
    and
    (no_goal_probability is null or no_goal_probability between 0 and 1)
    and
    (market_confidence is null or market_confidence between 0 and 1)
    and
    (model_loss is null or model_loss >= 0)
  );

alter table public.market_intelligence_match_snapshots
  drop constraint if exists
    market_intelligence_match_secondary_sum_check;

alter table public.market_intelligence_match_snapshots
  add constraint
    market_intelligence_match_secondary_sum_check
  check (
    (
      over_25_probability is null
      or under_25_probability is null
      or abs(
        (over_25_probability + under_25_probability) - 1
      ) <= 0.000100
    )
    and
    (
      goal_probability is null
      or no_goal_probability is null
      or abs(
        (goal_probability + no_goal_probability) - 1
      ) <= 0.000100
    )
  );

-- ============================================================================
-- 3. GRANULAR SIGNAL MOVEMENT LEDGER
--
-- Migration 216 already owns market_intelligence_movements with aggregate
-- H/X/A movement semantics. Do not overload or duplicate its snapshot keys.
--
-- This table is the detailed time-series layer used by Control Room trends.
-- ============================================================================

create table if not exists public.market_intelligence_signal_movements (
  id uuid primary key default gen_random_uuid(),

  fantagol_round_id uuid not null
    references public.fantagol_rounds(id)
    on delete restrict,

  match_id uuid not null
    references public.matches(id)
    on delete restrict,

  market_model_id uuid not null
    references public.market_intelligence_models(id)
    on delete restrict,

  previous_match_snapshot_id uuid not null
    references public.market_intelligence_match_snapshots(id)
    on delete restrict,

  current_match_snapshot_id uuid not null
    references public.market_intelligence_match_snapshots(id)
    on delete restrict,

  signal_type text not null,
  signal_key text not null,

  previous_probability numeric(10,8),
  current_probability numeric(10,8),

  delta_probability numeric(12,10),
  delta_percentage_points numeric(12,8),

  previous_rank integer,
  current_rank integer,
  rank_delta integer,

  movement_magnitude numeric(12,10) not null default 0,

  direction text not null,

  movement_hash text not null,

  metadata jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default clock_timestamp(),

  constraint market_intelligence_signal_movements_signal_type_check
    check (
      signal_type in (
        'EXACT',
        'SIGN',
        'TOTALS',
        'BTTS',
        'MARKET_CONFIDENCE',
        'FINAL_CONFIDENCE'
      )
    ),

  constraint market_intelligence_signal_movements_key_nonempty
    check (btrim(signal_key) <> ''),

  constraint market_intelligence_signal_movements_probability_check
    check (
      (
        previous_probability is null
        or previous_probability between 0 and 1
      )
      and
      (
        current_probability is null
        or current_probability between 0 and 1
      )
    ),

  constraint market_intelligence_signal_movements_rank_check
    check (
      (previous_rank is null or previous_rank > 0)
      and
      (current_rank is null or current_rank > 0)
    ),

  constraint market_intelligence_signal_movements_magnitude_check
    check (movement_magnitude >= 0),

  constraint market_intelligence_signal_movements_direction_check
    check (
      direction in ('UP', 'DOWN', 'FLAT')
    ),

  constraint market_intelligence_signal_movements_distinct_snapshot_check
    check (
      previous_match_snapshot_id <> current_match_snapshot_id
    ),

  constraint market_intelligence_signal_movements_unique
    unique (
      previous_match_snapshot_id,
      current_match_snapshot_id,
      signal_type,
      signal_key
    )
);

create index if not exists
  market_intelligence_signal_movements_match_idx
on public.market_intelligence_signal_movements (
  match_id,
  created_at desc
);

create index if not exists
  market_intelligence_signal_movements_current_idx
on public.market_intelligence_signal_movements (
  current_match_snapshot_id,
  signal_type,
  signal_key
);

create index if not exists
  market_intelligence_signal_movements_signal_idx
on public.market_intelligence_signal_movements (
  match_id,
  signal_type,
  signal_key,
  created_at desc
);

-- ============================================================================
-- 4. SIGNAL MOVEMENT PAIR INVARIANT
--
-- A granular movement may compare only two match snapshots that belong to:
--
--   * the same match
--   * the same Fantagol round
--   * the same Market Intelligence model
--
-- The denormalized match_id / fantagol_round_id / market_model_id stored on
-- the movement row must also agree with the canonical parent snapshots.
--
-- This prevents a runtime bug from constructing a mathematically valid delta
-- between semantically unrelated snapshots.
-- ============================================================================

create or replace function
public.validate_market_intelligence_signal_movement_pair()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_previous_match_id uuid;
  v_previous_round_id uuid;
  v_previous_model_id uuid;

  v_current_match_id uuid;
  v_current_round_id uuid;
  v_current_model_id uuid;
begin
  select
    previous_ms.match_id,
    previous_s.fantagol_round_id,
    previous_s.market_model_id

  into
    v_previous_match_id,
    v_previous_round_id,
    v_previous_model_id

  from public.market_intelligence_match_snapshots previous_ms

  join public.market_intelligence_snapshots previous_s
    on previous_s.id =
       previous_ms.market_intelligence_snapshot_id

  where previous_ms.id =
        new.previous_match_snapshot_id;

  if not found then
    raise exception
      using
        errcode = '23503',
        message =
          'MARKET_INTELLIGENCE_PREVIOUS_MATCH_SNAPSHOT_NOT_FOUND';
  end if;

  select
    current_ms.match_id,
    current_s.fantagol_round_id,
    current_s.market_model_id

  into
    v_current_match_id,
    v_current_round_id,
    v_current_model_id

  from public.market_intelligence_match_snapshots current_ms

  join public.market_intelligence_snapshots current_s
    on current_s.id =
       current_ms.market_intelligence_snapshot_id

  where current_ms.id =
        new.current_match_snapshot_id;

  if not found then
    raise exception
      using
        errcode = '23503',
        message =
          'MARKET_INTELLIGENCE_CURRENT_MATCH_SNAPSHOT_NOT_FOUND';
  end if;

  -- --------------------------------------------------------------
  -- Same canonical match.
  -- --------------------------------------------------------------

  if
    v_previous_match_id <> v_current_match_id
  then
    raise exception
      using
        errcode = '23514',
        message =
          'MARKET_INTELLIGENCE_MOVEMENT_MATCH_MISMATCH';
  end if;

  -- --------------------------------------------------------------
  -- Same canonical Fantagol round.
  -- --------------------------------------------------------------

  if
    v_previous_round_id <> v_current_round_id
  then
    raise exception
      using
        errcode = '23514',
        message =
          'MARKET_INTELLIGENCE_MOVEMENT_ROUND_MISMATCH';
  end if;

  -- --------------------------------------------------------------
  -- Same canonical model.
  -- --------------------------------------------------------------

  if
    v_previous_model_id <> v_current_model_id
  then
    raise exception
      using
        errcode = '23514',
        message =
          'MARKET_INTELLIGENCE_MOVEMENT_MODEL_MISMATCH';
  end if;

  -- --------------------------------------------------------------
  -- Row-level denormalized identity must match canonical identity.
  -- --------------------------------------------------------------

  if
    new.match_id <> v_current_match_id
  then
    raise exception
      using
        errcode = '23514',
        message =
          'MARKET_INTELLIGENCE_MOVEMENT_ROW_MATCH_MISMATCH';
  end if;

  if
    new.fantagol_round_id <> v_current_round_id
  then
    raise exception
      using
        errcode = '23514',
        message =
          'MARKET_INTELLIGENCE_MOVEMENT_ROW_ROUND_MISMATCH';
  end if;

  if
    new.market_model_id <> v_current_model_id
  then
    raise exception
      using
        errcode = '23514',
        message =
          'MARKET_INTELLIGENCE_MOVEMENT_ROW_MODEL_MISMATCH';
  end if;

  return new;
end;
$$;

revoke all
on function
public.validate_market_intelligence_signal_movement_pair()
from public, anon, authenticated;

grant execute
on function
public.validate_market_intelligence_signal_movement_pair()
to service_role;

drop trigger if exists
  validate_market_intelligence_signal_movement_pair_trg
on public.market_intelligence_signal_movements;

create trigger
  validate_market_intelligence_signal_movement_pair_trg
before insert
on public.market_intelligence_signal_movements
for each row
execute function
  public.validate_market_intelligence_signal_movement_pair();

-- ============================================================================
-- 5. IMMUTABILITY
-- ============================================================================

drop trigger if exists
  guard_market_intelligence_signal_movements_immutable_trg
on public.market_intelligence_signal_movements;

create trigger
  guard_market_intelligence_signal_movements_immutable_trg
before update or delete
on public.market_intelligence_signal_movements
for each row
execute function public.prevent_market_intelligence_immutable_mutation();

-- ============================================================================
-- 6. LATEST MATCH READ MODEL
-- ============================================================================

create or replace function
public.get_latest_market_intelligence_match_internal(
  p_match_id uuid
)
returns table (
  snapshot_id uuid,
  match_snapshot_id uuid,
  match_id uuid,
  fantagol_round_id uuid,

  captured_at timestamptz,
  snapshot_source text,

  home_probability numeric,
  draw_probability numeric,
  away_probability numeric,

  over_25_probability numeric,
  under_25_probability numeric,

  goal_probability numeric,
  no_goal_probability numeric,

  lambda_home numeric,
  lambda_away numeric,

  market_confidence numeric,
  final_confidence numeric,
  model_loss numeric,

  primary_outcome text,

  output_payload jsonb
)
language sql
stable
security definer
set search_path = public
as $$
  select
    s.id,
    ms.id,
    ms.match_id,
    s.fantagol_round_id,

    s.captured_at,
    s.snapshot_source,

    ms.home_probability,
    ms.draw_probability,
    ms.away_probability,

    ms.over_25_probability,
    ms.under_25_probability,

    ms.goal_probability,
    ms.no_goal_probability,

    ms.expected_home_goals as lambda_home,
    ms.expected_away_goals as lambda_away,

    ms.market_confidence,
    ms.confidence_score as final_confidence,
    ms.model_loss,

    ms.primary_outcome,

    ms.output_payload

  from public.market_intelligence_match_snapshots ms

  join public.market_intelligence_snapshots s
    on s.id = ms.market_intelligence_snapshot_id

  where ms.match_id = p_match_id

  order by
    s.captured_at desc nulls last,
    s.snapshot_version desc,
    ms.created_at desc

  limit 1;
$$;

-- ============================================================================
-- 7. MATCH HISTORY READ MODEL
-- ============================================================================

create or replace function
public.get_market_intelligence_match_history_internal(
  p_match_id uuid,
  p_limit integer default 32
)
returns table (
  snapshot_id uuid,
  match_snapshot_id uuid,
  match_id uuid,
  fantagol_round_id uuid,

  captured_at timestamptz,
  snapshot_source text,

  home_probability numeric,
  draw_probability numeric,
  away_probability numeric,

  over_25_probability numeric,
  under_25_probability numeric,

  goal_probability numeric,
  no_goal_probability numeric,

  lambda_home numeric,
  lambda_away numeric,

  market_confidence numeric,
  final_confidence numeric,
  model_loss numeric,

  primary_outcome text,

  output_payload jsonb
)
language sql
stable
security definer
set search_path = public
as $$
  select
    s.id,
    ms.id,
    ms.match_id,
    s.fantagol_round_id,

    s.captured_at,
    s.snapshot_source,

    ms.home_probability,
    ms.draw_probability,
    ms.away_probability,

    ms.over_25_probability,
    ms.under_25_probability,

    ms.goal_probability,
    ms.no_goal_probability,

    ms.expected_home_goals as lambda_home,
    ms.expected_away_goals as lambda_away,

    ms.market_confidence,
    ms.confidence_score as final_confidence,
    ms.model_loss,

    ms.primary_outcome,

    ms.output_payload

  from public.market_intelligence_match_snapshots ms

  join public.market_intelligence_snapshots s
    on s.id = ms.market_intelligence_snapshot_id

  where ms.match_id = p_match_id

  order by
    s.captured_at desc nulls last,
    s.snapshot_version desc,
    ms.created_at desc

  limit greatest(
    1,
    least(
      coalesce(p_limit, 32),
      128
    )
  );
$$;

-- ============================================================================
-- 8. GRANULAR TREND READ MODEL
-- ============================================================================

create or replace function
public.get_market_intelligence_match_movements_internal(
  p_match_id uuid,
  p_limit integer default 256
)
returns table (
  movement_id uuid,

  previous_match_snapshot_id uuid,
  current_match_snapshot_id uuid,

  signal_type text,
  signal_key text,

  previous_probability numeric,
  current_probability numeric,

  delta_probability numeric,
  delta_percentage_points numeric,

  previous_rank integer,
  current_rank integer,
  rank_delta integer,

  movement_magnitude numeric,
  direction text,

  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    mv.id,

    mv.previous_match_snapshot_id,
    mv.current_match_snapshot_id,

    mv.signal_type,
    mv.signal_key,

    mv.previous_probability,
    mv.current_probability,

    mv.delta_probability,
    mv.delta_percentage_points,

    mv.previous_rank,
    mv.current_rank,
    mv.rank_delta,

    mv.movement_magnitude,
    mv.direction,

    mv.created_at

  from public.market_intelligence_signal_movements mv

  where mv.match_id = p_match_id

  order by
    mv.created_at desc,
    mv.id desc

  limit greatest(
    1,
    least(
      coalesce(p_limit, 256),
      1024
    )
  );
$$;

-- ============================================================================
-- 9. SECURITY
-- ============================================================================

alter table public.market_intelligence_signal_movements
  enable row level security;

drop policy if exists
  market_intelligence_signal_movements_service_all
on public.market_intelligence_signal_movements;

create policy
  market_intelligence_signal_movements_service_all
on public.market_intelligence_signal_movements
for all
to service_role
using (true)
with check (true);

revoke all
on public.market_intelligence_signal_movements
from anon, authenticated;

grant select, insert
on public.market_intelligence_signal_movements
to service_role;

revoke all
on function
public.get_latest_market_intelligence_match_internal(uuid)
from public, anon, authenticated;

revoke all
on function
public.get_market_intelligence_match_history_internal(uuid, integer)
from public, anon, authenticated;

revoke all
on function
public.get_market_intelligence_match_movements_internal(uuid, integer)
from public, anon, authenticated;

grant execute
on function
public.get_latest_market_intelligence_match_internal(uuid)
to service_role;

grant execute
on function
public.get_market_intelligence_match_history_internal(uuid, integer)
to service_role;

grant execute
on function
public.get_market_intelligence_match_movements_internal(uuid, integer)
to service_role;

comment on table public.market_intelligence_signal_movements is
'Immutable granular BM_INTERPOLATED signal movement ledger. Extends the aggregate movement foundation introduced by migration 216.';

comment on function public.get_latest_market_intelligence_match_internal(uuid) is
'Latest persisted BM_INTERPOLATED match snapshot. Exact/score distribution is returned through output_payload.';

comment on function public.get_market_intelligence_match_history_internal(uuid, integer) is
'Temporal BM_INTERPOLATED snapshot history for one match.';

comment on function public.get_market_intelligence_match_movements_internal(uuid, integer) is
'Granular BM_INTERPOLATED Exact, Sign, Totals, BTTS and confidence movement history.';

commit;