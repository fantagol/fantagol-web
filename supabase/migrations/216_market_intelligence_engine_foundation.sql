-- ================================================================
-- FANTAGOL
-- MIGRATION 216
-- MARKET INTELLIGENCE ENGINE FOUNDATION
-- ================================================================
--
-- PURPOSE
--   Establish the independent Market Intelligence domain.
--
-- ARCHITECTURAL CONTRACT
--   - consumes market/odds evidence only
--   - MUST NOT consume Community Intelligence data
--   - first certified model: BM_INTERPOLATED
--   - immutable/versioned model snapshots
--   - deterministic hashes
--   - frontend remains a passive read-model consumer
--   - Community/Market comparison belongs to a later aggregator layer
--
-- IMPORTANT
--   This migration does NOT calculate betting recommendations.
--   This migration does NOT modify Community Intelligence.
--   This migration does NOT modify Surprise scoring.
--   This migration does NOT call external providers.
-- ================================================================

begin;

create extension if not exists pgcrypto;


-- ================================================================
-- 1. MARKET MODEL REGISTRY
-- ================================================================

create table if not exists public.market_intelligence_models (
    id uuid primary key default gen_random_uuid(),

    model_code text not null,
    model_version integer not null default 1,

    display_name text not null,
    description text null,

    status text not null default 'active',

    algorithm_version text not null,

    configuration jsonb not null default '{}'::jsonb,
    metadata jsonb not null default '{}'::jsonb,

    created_at timestamptz not null default now(),

    constraint market_intelligence_models_code_nonempty
        check (btrim(model_code) <> ''),

    constraint market_intelligence_models_version_positive
        check (model_version > 0),

    constraint market_intelligence_models_algorithm_nonempty
        check (btrim(algorithm_version) <> ''),

    constraint market_intelligence_models_status_check
        check (
            status in (
                'active',
                'disabled',
                'deprecated'
            )
        ),

    constraint market_intelligence_models_code_version_unique
        unique (model_code, model_version)
);


-- ================================================================
-- 2. ROUND SNAPSHOTS
-- ================================================================

create table if not exists public.market_intelligence_snapshots (
    id uuid primary key default gen_random_uuid(),

    fantagol_round_id uuid not null
        references public.fantagol_rounds(id)
        on delete restrict,

    market_model_id uuid not null
        references public.market_intelligence_models(id)
        on delete restrict,

    snapshot_version integer not null,

    status text not null default 'building',

    built_at timestamptz null,
    frozen_at timestamptz null,

    required_match_count integer not null default 0,
    captured_match_count integer not null default 0,

    input_hash text null,
    snapshot_hash text null,

    quality_status text not null default 'pending',
    quality_score numeric(8,6) null,

    metadata jsonb not null default '{}'::jsonb,

    schema_version integer not null default 1,

    created_at timestamptz not null default now(),

    constraint market_intelligence_snapshots_version_positive
        check (snapshot_version > 0),

    constraint market_intelligence_snapshots_schema_positive
        check (schema_version > 0),

    constraint market_intelligence_snapshots_status_check
        check (
            status in (
                'building',
                'ready',
                'failed'
            )
        ),

    constraint market_intelligence_snapshots_quality_check
        check (
            quality_status in (
                'pending',
                'healthy',
                'degraded',
                'insufficient',
                'failed'
            )
        ),

    constraint market_intelligence_snapshots_counts_check
        check (
            required_match_count >= 0
            and captured_match_count >= 0
            and captured_match_count <= required_match_count
        ),

    constraint market_intelligence_snapshots_quality_score_check
        check (
            quality_score is null
            or (
                quality_score >= 0
                and quality_score <= 1
            )
        ),

    constraint market_intelligence_snapshots_ready_check
        check (
            status <> 'ready'
            or (
                built_at is not null
                and frozen_at is not null
                and input_hash is not null
                and snapshot_hash is not null
                and required_match_count > 0
                and captured_match_count = required_match_count
            )
        ),

    constraint market_intelligence_snapshots_round_model_version_unique
        unique (
            fantagol_round_id,
            market_model_id,
            snapshot_version
        )
);


-- ================================================================
-- 3. PER-MATCH MODEL OUTPUT
-- ================================================================

create table if not exists public.market_intelligence_match_snapshots (
    id uuid primary key default gen_random_uuid(),

    market_intelligence_snapshot_id uuid not null
        references public.market_intelligence_snapshots(id)
        on delete cascade,

    match_id uuid not null
        references public.matches(id)
        on delete restrict,

    odds_market_snapshot_id uuid not null
        references public.odds_market_snapshots(id)
        on delete restrict,

    slot_number integer not null,

    model_code text not null,
    algorithm_version text not null,

    home_probability numeric(8,6) not null,
    draw_probability numeric(8,6) not null,
    away_probability numeric(8,6) not null,

    expected_home_goals numeric(10,6) null,
    expected_away_goals numeric(10,6) null,

    primary_outcome text not null,

    confidence_score numeric(8,6) null,

    input_payload jsonb not null default '{}'::jsonb,
    output_payload jsonb not null default '{}'::jsonb,

    input_hash text not null,
    output_hash text not null,

    created_at timestamptz not null default now(),

    constraint market_intelligence_match_slot_positive
        check (slot_number > 0),

    constraint market_intelligence_match_model_nonempty
        check (btrim(model_code) <> ''),

    constraint market_intelligence_match_algorithm_nonempty
        check (btrim(algorithm_version) <> ''),

    constraint market_intelligence_match_probability_ranges
        check (
            home_probability between 0 and 1
            and draw_probability between 0 and 1
            and away_probability between 0 and 1
        ),

    constraint market_intelligence_match_probability_sum
        check (
            abs(
                (
                    home_probability
                    + draw_probability
                    + away_probability
                ) - 1
            ) <= 0.000100
        ),

    constraint market_intelligence_match_outcome_check
        check (
            primary_outcome in ('1', 'X', '2')
        ),

    constraint market_intelligence_match_confidence_check
        check (
            confidence_score is null
            or confidence_score between 0 and 1
        ),

    constraint market_intelligence_match_snapshot_match_unique
        unique (
            market_intelligence_snapshot_id,
            match_id
        ),

    constraint market_intelligence_match_snapshot_slot_unique
        unique (
            market_intelligence_snapshot_id,
            slot_number
        )
);


-- ================================================================
-- 4. MARKET MOVEMENT FOUNDATION
-- ================================================================

create table if not exists public.market_intelligence_movements (
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

    movement_type text not null,

    home_delta numeric(10,6) not null,
    draw_delta numeric(10,6) not null,
    away_delta numeric(10,6) not null,

    magnitude numeric(10,6) not null,

    direction text not null,

    movement_hash text not null,

    metadata jsonb not null default '{}'::jsonb,

    created_at timestamptz not null default now(),

    constraint market_intelligence_movements_type_check
        check (
            movement_type in (
                'probability_shift',
                'favorite_shift',
                'confidence_shift'
            )
        ),

    constraint market_intelligence_movements_direction_check
        check (
            direction in (
                'home',
                'draw',
                'away',
                'neutral'
            )
        ),

    constraint market_intelligence_movements_magnitude_check
        check (magnitude >= 0),

    constraint market_intelligence_movements_distinct_snapshots
        check (
            previous_match_snapshot_id <>
            current_match_snapshot_id
        ),

    constraint market_intelligence_movements_unique
        unique (
            previous_match_snapshot_id,
            current_match_snapshot_id,
            movement_type
        )
);


-- ================================================================
-- 5. EVENTS / OBSERVABILITY
-- ================================================================

create table if not exists public.market_intelligence_events (
    id uuid primary key default gen_random_uuid(),

    fantagol_round_id uuid null
        references public.fantagol_rounds(id)
        on delete set null,

    market_intelligence_snapshot_id uuid null
        references public.market_intelligence_snapshots(id)
        on delete set null,

    match_id uuid null
        references public.matches(id)
        on delete set null,

    event_type text not null,
    status text not null,

    correlation_id uuid null,

    details jsonb not null default '{}'::jsonb,

    occurred_at timestamptz not null default now(),

    constraint market_intelligence_events_type_nonempty
        check (btrim(event_type) <> ''),

    constraint market_intelligence_events_status_nonempty
        check (btrim(status) <> '')
);


-- ================================================================
-- 6. INDEXES
-- ================================================================

create index if not exists
market_intelligence_snapshots_round_idx
on public.market_intelligence_snapshots (
    fantagol_round_id,
    snapshot_version desc
);

create index if not exists
market_intelligence_snapshots_model_idx
on public.market_intelligence_snapshots (
    market_model_id,
    created_at desc
);

create index if not exists
market_intelligence_snapshots_hash_idx
on public.market_intelligence_snapshots (
    snapshot_hash
)
where snapshot_hash is not null;

create index if not exists
market_intelligence_match_snapshot_slot_idx
on public.market_intelligence_match_snapshots (
    market_intelligence_snapshot_id,
    slot_number
);

create index if not exists
market_intelligence_match_match_idx
on public.market_intelligence_match_snapshots (
    match_id,
    created_at desc
);

create index if not exists
market_intelligence_match_odds_idx
on public.market_intelligence_match_snapshots (
    odds_market_snapshot_id
);

create index if not exists
market_intelligence_movements_match_idx
on public.market_intelligence_movements (
    match_id,
    created_at desc
);

create index if not exists
market_intelligence_events_round_idx
on public.market_intelligence_events (
    fantagol_round_id,
    occurred_at desc
);


-- ================================================================
-- 7. IMMUTABILITY
-- ================================================================

create or replace function
public.prevent_market_intelligence_immutable_mutation()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $function$
begin
    raise exception using
        errcode = 'P0001',
        message =
            'MARKET_INTELLIGENCE_IMMUTABLE_ARTIFACT';
end;
$function$;


drop trigger if exists
guard_market_intelligence_match_snapshots_immutable_trg
on public.market_intelligence_match_snapshots;

create trigger
guard_market_intelligence_match_snapshots_immutable_trg
before update or delete
on public.market_intelligence_match_snapshots
for each row
execute function
public.prevent_market_intelligence_immutable_mutation();


drop trigger if exists
guard_market_intelligence_movements_immutable_trg
on public.market_intelligence_movements;

create trigger
guard_market_intelligence_movements_immutable_trg
before update or delete
on public.market_intelligence_movements
for each row
execute function
public.prevent_market_intelligence_immutable_mutation();


-- ================================================================
-- 8. REGISTER BM_INTERPOLATED
-- ================================================================

insert into public.market_intelligence_models (
    model_code,
    model_version,
    display_name,
    description,
    status,
    algorithm_version,
    configuration,
    metadata
)
values (
    'BM_INTERPOLATED',
    1,
    'Bookmaker Interpolated',
    'Independent bookmaker-market interpolation model.',
    'active',
    'BM_INTERPOLATED_V1',
    jsonb_build_object(
        'market', 'h2h',
        'probability_normalization', 'overround_removed',
        'community_input', false
    ),
    jsonb_build_object(
        'foundation_migration', 216,
        'prescriptive_output', false
    )
)
on conflict (
    model_code,
    model_version
)
do nothing;


-- ================================================================
-- 9. RLS
-- ================================================================

alter table
public.market_intelligence_models
enable row level security;

alter table
public.market_intelligence_snapshots
enable row level security;

alter table
public.market_intelligence_match_snapshots
enable row level security;

alter table
public.market_intelligence_movements
enable row level security;

alter table
public.market_intelligence_events
enable row level security;


revoke all
on public.market_intelligence_models
from public, anon, authenticated;

revoke all
on public.market_intelligence_snapshots
from public, anon, authenticated;

revoke all
on public.market_intelligence_match_snapshots
from public, anon, authenticated;

revoke all
on public.market_intelligence_movements
from public, anon, authenticated;

revoke all
on public.market_intelligence_events
from public, anon, authenticated;


grant select, insert, update
on public.market_intelligence_models
to service_role;

grant select, insert, update
on public.market_intelligence_snapshots
to service_role;

grant select, insert
on public.market_intelligence_match_snapshots
to service_role;

grant select, insert
on public.market_intelligence_movements
to service_role;

grant select, insert
on public.market_intelligence_events
to service_role;


-- ================================================================
-- 10. COMMENTS
-- ================================================================

comment on table
public.market_intelligence_models
is
'Registry of independent versioned Market Intelligence models.';

comment on table
public.market_intelligence_snapshots
is
'Round-scoped versioned Market Intelligence snapshots derived only from market evidence.';

comment on table
public.market_intelligence_match_snapshots
is
'Immutable per-match outputs produced by a Market Intelligence model from canonical odds evidence.';

comment on table
public.market_intelligence_movements
is
'Immutable descriptive movement artifacts comparing consecutive Market Intelligence match snapshots.';

comment on table
public.market_intelligence_events
is
'Operational and observability event stream for the Market Intelligence Engine.';


-- ================================================================
-- 11. FOUNDATION ASSERTIONS
-- ================================================================

do $block$
begin

    if to_regclass(
        'public.market_intelligence_models'
    ) is null then
        raise exception
            'MIGRATION_216_MODELS_TABLE_MISSING';
    end if;

    if to_regclass(
        'public.market_intelligence_snapshots'
    ) is null then
        raise exception
            'MIGRATION_216_SNAPSHOTS_TABLE_MISSING';
    end if;

    if to_regclass(
        'public.market_intelligence_match_snapshots'
    ) is null then
        raise exception
            'MIGRATION_216_MATCH_SNAPSHOTS_TABLE_MISSING';
    end if;

    if to_regclass(
        'public.market_intelligence_movements'
    ) is null then
        raise exception
            'MIGRATION_216_MOVEMENTS_TABLE_MISSING';
    end if;

    if to_regclass(
        'public.market_intelligence_events'
    ) is null then
        raise exception
            'MIGRATION_216_EVENTS_TABLE_MISSING';
    end if;

    if not exists (
        select 1
        from public.market_intelligence_models
        where model_code = 'BM_INTERPOLATED'
          and model_version = 1
          and algorithm_version =
              'BM_INTERPOLATED_V1'
    ) then
        raise exception
            'MIGRATION_216_BM_INTERPOLATED_MISSING';
    end if;

end;
$block$;

commit;