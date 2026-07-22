-- ============================================================================
-- FANTAGOL
-- Migration 097
-- Community Intelligence Engine Foundation
-- Milestone 9.1
-- ============================================================================
-- Purpose:
--   Global anonymous community analytics, immutable/versioned snapshots,
--   consensus, exact distributions, trend/insight foundation, read models,
--   RPC contracts, RLS, grants and observability.
--
-- Architectural constraints:
--   - reads only submitted/locked predictions
--   - never exposes user_id, league_member_id or league_id through client RPCs
--   - never mutates Prediction/Strategy/Scoring/Simulation/Certification domains
--   - snapshots are immutable after ready/frozen
--   - market context is optional and references existing odds snapshots
-- ============================================================================

begin;

create extension if not exists pgcrypto;

-- ============================================================================
-- 1. CANONICAL TABLES
-- ============================================================================

create table if not exists public.community_snapshots (
    id uuid primary key default gen_random_uuid(),
    fantagol_round_id uuid not null
        references public.fantagol_rounds(id) on delete cascade,
    snapshot_version integer not null,
    phase text not null,
    status text not null default 'building',
    source_prediction_count integer not null default 0,
    source_member_count integer not null default 0,
    source_league_count integer not null default 0,
    source_match_count integer not null default 0,
    eligible_prediction_count integer not null default 0,
    excluded_prediction_count integer not null default 0,
    quality_status text not null default 'insufficient',
    quality_score numeric(7,4) not null default 0,
    minimum_sample_satisfied boolean not null default false,
    input_hash text not null default '',
    output_hash text not null default '',
    engine_version text not null default 'community-intelligence-v1',
    snapshot_schema_version integer not null default 1,
    requested_at timestamptz not null default clock_timestamp(),
    built_at timestamptz null,
    frozen_at timestamptz null,
    archived_at timestamptz null,
    metadata jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default clock_timestamp(),

    constraint community_snapshots_round_version_unique
        unique (fantagol_round_id, snapshot_version),

    constraint community_snapshots_phase_check
        check (phase in ('pre_live','lock','live','post_live','historical')),

    constraint community_snapshots_status_check
        check (status in ('building','ready','failed','frozen','archived')),

    constraint community_snapshots_quality_status_check
        check (quality_status in ('insufficient','emerging','stable','high_confidence')),

    constraint community_snapshots_version_positive
        check (snapshot_version > 0),

    constraint community_snapshots_counts_nonnegative
        check (
            source_prediction_count >= 0
            and source_member_count >= 0
            and source_league_count >= 0
            and source_match_count >= 0
            and eligible_prediction_count >= 0
            and excluded_prediction_count >= 0
        ),

    constraint community_snapshots_quality_score_range
        check (quality_score between 0 and 100),

    constraint community_snapshots_schema_version_positive
        check (snapshot_schema_version > 0),

    constraint community_snapshots_ready_hashes_check
        check (
            status not in ('ready','frozen')
            or (length(input_hash) > 0 and length(output_hash) > 0 and built_at is not null)
        ),

    constraint community_snapshots_frozen_at_check
        check (status <> 'frozen' or frozen_at is not null)
);

create table if not exists public.community_snapshot_registry (
    id uuid primary key default gen_random_uuid(),
    fantagol_round_id uuid not null
        references public.fantagol_rounds(id) on delete cascade,
    current_phase text not null default 'pre_live',
    current_snapshot_id uuid null
        references public.community_snapshots(id) on delete set null,
    latest_pre_live_snapshot_id uuid null
        references public.community_snapshots(id) on delete set null,
    lock_snapshot_id uuid null
        references public.community_snapshots(id) on delete set null,
    latest_live_snapshot_id uuid null
        references public.community_snapshots(id) on delete set null,
    post_live_snapshot_id uuid null
        references public.community_snapshots(id) on delete set null,
    historical_snapshot_id uuid null
        references public.community_snapshots(id) on delete set null,
    status text not null default 'idle',
    last_requested_at timestamptz null,
    last_completed_at timestamptz null,
    last_failed_at timestamptz null,
    next_refresh_at timestamptz null,
    snapshot_count integer not null default 0,
    version integer not null default 1,
    created_at timestamptz not null default clock_timestamp(),
    updated_at timestamptz not null default clock_timestamp(),

    constraint community_snapshot_registry_round_unique
        unique (fantagol_round_id),

    constraint community_snapshot_registry_phase_check
        check (current_phase in ('pre_live','lock','live','post_live','historical')),

    constraint community_snapshot_registry_status_check
        check (status in ('idle','scheduled','building','ready','frozen','failed','archived')),

    constraint community_snapshot_registry_count_nonnegative
        check (snapshot_count >= 0),

    constraint community_snapshot_registry_version_positive
        check (version > 0)
);

create table if not exists public.community_match_snapshots (
    id uuid primary key default gen_random_uuid(),
    community_snapshot_id uuid not null
        references public.community_snapshots(id) on delete cascade,
    fantagol_round_id uuid not null
        references public.fantagol_rounds(id) on delete cascade,
    match_id uuid not null
        references public.matches(id) on delete restrict,
    slot_number integer not null,
    prediction_count integer not null default 0,
    member_count integer not null default 0,
    league_count integer not null default 0,
    home_pick_count integer not null default 0,
    draw_pick_count integer not null default 0,
    away_pick_count integer not null default 0,
    home_pick_percent numeric(9,6) not null default 0,
    draw_pick_percent numeric(9,6) not null default 0,
    away_pick_percent numeric(9,6) not null default 0,
    over_2_5_count integer not null default 0,
    under_2_5_count integer not null default 0,
    over_2_5_percent numeric(9,6) not null default 0,
    under_2_5_percent numeric(9,6) not null default 0,
    goal_count integer not null default 0,
    no_goal_count integer not null default 0,
    goal_percent numeric(9,6) not null default 0,
    no_goal_percent numeric(9,6) not null default 0,
    avg_home_goals numeric(9,6) not null default 0,
    avg_away_goals numeric(9,6) not null default 0,
    avg_total_goals numeric(9,6) not null default 0,
    consensus_outcome text null,
    consensus_percent numeric(9,6) not null default 0,
    consensus_index numeric(9,6) not null default 0,
    confidence_index numeric(9,6) not null default 0,
    chaos_index numeric(9,6) not null default 0,
    exact_dispersion_index numeric(9,6) not null default 0,
    sample_quality_status text not null default 'insufficient',
    sample_quality_score numeric(9,6) not null default 0,
    market_snapshot_id uuid null
        references public.odds_market_snapshots(id) on delete set null,
    market_context jsonb not null default '{}'::jsonb,
    trend_context jsonb not null default '{}'::jsonb,
    insight_context jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default clock_timestamp(),

    constraint community_match_snapshots_snapshot_match_unique
        unique (community_snapshot_id, match_id),

    constraint community_match_snapshots_slot_positive
        check (slot_number > 0),

    constraint community_match_snapshots_counts_nonnegative
        check (
            prediction_count >= 0
            and member_count >= 0
            and league_count >= 0
            and home_pick_count >= 0
            and draw_pick_count >= 0
            and away_pick_count >= 0
            and over_2_5_count >= 0
            and under_2_5_count >= 0
            and goal_count >= 0
            and no_goal_count >= 0
        ),

    constraint community_match_snapshots_consensus_outcome_check
        check (consensus_outcome is null or consensus_outcome in ('1','X','2')),

    constraint community_match_snapshots_quality_status_check
        check (sample_quality_status in ('insufficient','emerging','stable','high_confidence')),

    constraint community_match_snapshots_percent_ranges
        check (
            home_pick_percent between 0 and 100
            and draw_pick_percent between 0 and 100
            and away_pick_percent between 0 and 100
            and over_2_5_percent between 0 and 100
            and under_2_5_percent between 0 and 100
            and goal_percent between 0 and 100
            and no_goal_percent between 0 and 100
            and consensus_percent between 0 and 100
            and consensus_index between 0 and 100
            and confidence_index between 0 and 100
            and chaos_index between 0 and 100
            and exact_dispersion_index between 0 and 100
            and sample_quality_score between 0 and 100
        ),

    constraint community_match_snapshots_sign_sum_check
        check (
            prediction_count = 0
            or abs((home_pick_percent + draw_pick_percent + away_pick_percent) - 100) <= 0.01
        ),

    constraint community_match_snapshots_ou_sum_check
        check (
            prediction_count = 0
            or abs((over_2_5_percent + under_2_5_percent) - 100) <= 0.01
        ),

    constraint community_match_snapshots_gng_sum_check
        check (
            prediction_count = 0
            or abs((goal_percent + no_goal_percent) - 100) <= 0.01
        )
);

create table if not exists public.community_exact_distributions (
    id uuid primary key default gen_random_uuid(),
    community_snapshot_id uuid not null
        references public.community_snapshots(id) on delete cascade,
    match_id uuid not null
        references public.matches(id) on delete restrict,
    home_prediction integer not null,
    away_prediction integer not null,
    prediction_count integer not null,
    prediction_percent numeric(9,6) not null,
    rank integer not null,
    is_top_exact boolean not null default false,
    change_from_previous numeric(9,6) null,
    created_at timestamptz not null default clock_timestamp(),

    constraint community_exact_distributions_unique
        unique (community_snapshot_id, match_id, home_prediction, away_prediction),

    constraint community_exact_distributions_score_range
        check (
            home_prediction between 0 and 9
            and away_prediction between 0 and 9
        ),

    constraint community_exact_distributions_prediction_count_positive
        check (prediction_count > 0),

    constraint community_exact_distributions_percent_range
        check (prediction_percent between 0 and 100),

    constraint community_exact_distributions_rank_positive
        check (rank > 0)
);

create unique index if not exists community_exact_distributions_one_rank_one
    on public.community_exact_distributions (community_snapshot_id, match_id)
    where rank = 1;

create table if not exists public.community_trends (
    id uuid primary key default gen_random_uuid(),
    fantagol_round_id uuid not null
        references public.fantagol_rounds(id) on delete cascade,
    match_id uuid not null
        references public.matches(id) on delete restrict,
    from_snapshot_id uuid not null
        references public.community_snapshots(id) on delete cascade,
    to_snapshot_id uuid not null
        references public.community_snapshots(id) on delete cascade,
    window_code text not null,
    metric_code text not null,
    outcome_code text null,
    from_value numeric(12,6) not null,
    to_value numeric(12,6) not null,
    delta_value numeric(12,6) not null,
    delta_percent numeric(12,6) null,
    direction text not null,
    velocity numeric(12,6) not null default 0,
    stability numeric(12,6) not null default 0,
    momentum text not null,
    late_shift boolean not null default false,
    created_at timestamptz not null default clock_timestamp(),

    constraint community_trends_snapshot_pair_check
        check (from_snapshot_id <> to_snapshot_id),

    constraint community_trends_window_check
        check (window_code in ('snapshot_to_snapshot','last_6h','last_24h','since_open','late_window')),

    constraint community_trends_metric_check
        check (metric_code in (
            'sign_share','exact_share','over_under_share','goal_no_goal_share',
            'consensus_index','confidence_index','chaos_index'
        )),

    constraint community_trends_direction_check
        check (direction in ('rising','stable','falling')),

    constraint community_trends_momentum_check
        check (momentum in ('rising','stable','falling')),

    constraint community_trends_stability_range
        check (stability between 0 and 100)
);

create unique index if not exists community_trends_unique
    on public.community_trends (
        fantagol_round_id,
        match_id,
        from_snapshot_id,
        to_snapshot_id,
        window_code,
        metric_code,
        coalesce(outcome_code, '')
    );

create table if not exists public.community_insights (
    id uuid primary key default gen_random_uuid(),
    community_snapshot_id uuid not null
        references public.community_snapshots(id) on delete cascade,
    match_id uuid null
        references public.matches(id) on delete restrict,
    scope text not null,
    insight_code text not null,
    severity text not null,
    priority integer not null,
    message_key text not null,
    parameters jsonb not null default '{}'::jsonb,
    rule_version text not null default 'community-insight-v1',
    created_at timestamptz not null default clock_timestamp(),

    constraint community_insights_scope_check
        check (scope in ('round','match','market','trend','quality')),

    constraint community_insights_severity_check
        check (severity in ('info','notable','high')),

    constraint community_insights_priority_nonnegative
        check (priority >= 0),

    constraint community_insights_code_nonempty
        check (length(trim(insight_code)) > 0),

    constraint community_insights_message_key_nonempty
        check (length(trim(message_key)) > 0)
);

create table if not exists public.community_snapshot_events (
    id uuid primary key default gen_random_uuid(),
    fantagol_round_id uuid not null
        references public.fantagol_rounds(id) on delete cascade,
    community_snapshot_id uuid null
        references public.community_snapshots(id) on delete set null,
    event_type text not null,
    event_version integer not null default 1,
    status text not null,
    payload jsonb not null default '{}'::jsonb,
    correlation_id uuid null,
    causation_id uuid null,
    occurred_at timestamptz not null default clock_timestamp(),
    created_at timestamptz not null default clock_timestamp(),

    constraint community_snapshot_events_type_check
        check (event_type in (
            'snapshot_requested',
            'snapshot_build_started',
            'snapshot_build_completed',
            'snapshot_build_failed',
            'snapshot_frozen',
            'snapshot_archived',
            'consensus_changed',
            'trend_updated',
            'insight_generated'
        )),

    constraint community_snapshot_events_version_positive
        check (event_version > 0),

    constraint community_snapshot_events_status_nonempty
        check (length(trim(status)) > 0)
);

-- ============================================================================
-- 2. INDEXES
-- ============================================================================

create index if not exists community_snapshots_round_phase_version_idx
    on public.community_snapshots (fantagol_round_id, phase, snapshot_version desc);

create index if not exists community_snapshots_status_built_idx
    on public.community_snapshots (status, built_at desc);

create index if not exists community_snapshots_input_hash_idx
    on public.community_snapshots (
        fantagol_round_id, phase, input_hash, engine_version, snapshot_schema_version
    );

create unique index if not exists community_snapshots_idempotency_unique
    on public.community_snapshots (
        fantagol_round_id, phase, input_hash, engine_version, snapshot_schema_version
    )
    where status in ('ready','frozen');

create index if not exists community_snapshot_registry_status_idx
    on public.community_snapshot_registry (status, next_refresh_at);

create index if not exists community_match_snapshots_snapshot_slot_idx
    on public.community_match_snapshots (community_snapshot_id, slot_number);

create index if not exists community_match_snapshots_match_snapshot_idx
    on public.community_match_snapshots (match_id, community_snapshot_id);

create index if not exists community_exact_distributions_snapshot_match_rank_idx
    on public.community_exact_distributions (community_snapshot_id, match_id, rank);

create index if not exists community_trends_round_match_metric_created_idx
    on public.community_trends (fantagol_round_id, match_id, metric_code, created_at desc);

create index if not exists community_insights_snapshot_match_priority_idx
    on public.community_insights (community_snapshot_id, match_id, priority);

create index if not exists community_snapshot_events_round_occurred_idx
    on public.community_snapshot_events (fantagol_round_id, occurred_at desc);

create index if not exists community_snapshot_events_snapshot_idx
    on public.community_snapshot_events (community_snapshot_id, occurred_at desc);

-- ============================================================================
-- 3. PURE HELPERS
-- ============================================================================

create or replace function public.community_percentage(
    p_count bigint,
    p_total bigint
)
returns numeric
language sql
immutable
strict
set search_path = public
as $$
    select case
        when p_total <= 0 then 0::numeric
        else (p_count::numeric / p_total::numeric) * 100::numeric
    end
$$;

create or replace function public.community_normalized_entropy(
    p_values numeric[]
)
returns numeric
language plpgsql
immutable
set search_path = public
as $$
declare
    v_total numeric := 0;
    v_entropy numeric := 0;
    v_nonzero integer := 0;
    v_value numeric;
    v_probability numeric;
begin
    if p_values is null or cardinality(p_values) = 0 then
        return 0;
    end if;

    foreach v_value in array p_values loop
        if coalesce(v_value, 0) > 0 then
            v_total := v_total + v_value;
            v_nonzero := v_nonzero + 1;
        end if;
    end loop;

    if v_total <= 0 or v_nonzero <= 1 then
        return 0;
    end if;

    foreach v_value in array p_values loop
        if coalesce(v_value, 0) > 0 then
            v_probability := v_value / v_total;
            v_entropy := v_entropy - (v_probability * ln(v_probability));
        end if;
    end loop;

    return greatest(0, least(1, v_entropy / ln(v_nonzero::numeric)));
end;
$$;

create or replace function public.community_confidence_index(
    p_home numeric,
    p_draw numeric,
    p_away numeric
)
returns numeric
language sql
immutable
set search_path = public
as $$
    select greatest(
        0::numeric,
        least(
            100::numeric,
            100::numeric - (
                public.community_normalized_entropy(array[
                    coalesce(p_home,0),
                    coalesce(p_draw,0),
                    coalesce(p_away,0)
                ]) * 100::numeric
            )
        )
    )
$$;

create or replace function public.community_exact_dispersion_index(
    p_counts numeric[]
)
returns numeric
language sql
immutable
set search_path = public
as $$
    select greatest(
        0::numeric,
        least(
            100::numeric,
            public.community_normalized_entropy(p_counts) * 100::numeric
        )
    )
$$;

create or replace function public.community_quality_status(
    p_prediction_count integer,
    p_member_count integer,
    p_league_count integer,
    p_match_coverage numeric
)
returns text
language sql
immutable
set search_path = public
as $$
    select case
        when coalesce(p_prediction_count,0) < 5
          or coalesce(p_member_count,0) < 3
          or coalesce(p_league_count,0) < 1
          or coalesce(p_match_coverage,0) < 50
            then 'insufficient'
        when p_prediction_count < 50
          or p_member_count < 10
          or p_match_coverage < 80
            then 'emerging'
        when p_prediction_count < 200
          or p_member_count < 50
            then 'stable'
        else 'high_confidence'
    end
$$;

create or replace function public.community_quality_score(
    p_prediction_count integer,
    p_member_count integer,
    p_league_count integer,
    p_match_coverage numeric
)
returns numeric
language sql
immutable
set search_path = public
as $$
    select greatest(
        0::numeric,
        least(
            100::numeric,
            least(coalesce(p_prediction_count,0)::numeric / 100::numeric, 1::numeric) * 35::numeric
          + least(coalesce(p_member_count,0)::numeric / 30::numeric, 1::numeric) * 30::numeric
          + least(coalesce(p_league_count,0)::numeric / 10::numeric, 1::numeric) * 15::numeric
          + least(coalesce(p_match_coverage,0)::numeric / 100::numeric, 1::numeric) * 20::numeric
        )
    )
$$;

-- ============================================================================
-- 4. VALIDATION AND IMMUTABILITY TRIGGERS
-- ============================================================================

create or replace function public.validate_community_registry_snapshot_scope()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_snapshot_id uuid;
    v_snapshot_round_id uuid;
begin
    foreach v_snapshot_id in array array[
        new.current_snapshot_id,
        new.latest_pre_live_snapshot_id,
        new.lock_snapshot_id,
        new.latest_live_snapshot_id,
        new.post_live_snapshot_id,
        new.historical_snapshot_id
    ] loop
        if v_snapshot_id is not null then
            select fantagol_round_id
              into v_snapshot_round_id
              from public.community_snapshots
             where id = v_snapshot_id;

            if v_snapshot_round_id is null
               or v_snapshot_round_id <> new.fantagol_round_id then
                raise exception using
                    errcode = '23514',
                    message = 'COMMUNITY_REGISTRY_SNAPSHOT_SCOPE_MISMATCH';
            end if;
        end if;
    end loop;

    if tg_op = 'UPDATE'
       and old.lock_snapshot_id is not null
       and new.lock_snapshot_id is distinct from old.lock_snapshot_id
       and coalesce(current_setting('fantagol.allow_community_lock_rebuild', true), 'off') <> 'on' then
        raise exception using
            errcode = '55000',
            message = 'COMMUNITY_LOCK_SNAPSHOT_ALREADY_FROZEN';
    end if;

    new.updated_at := clock_timestamp();
    new.version := case when tg_op = 'UPDATE' then old.version + 1 else new.version end;
    return new;
end;
$$;

drop trigger if exists validate_community_registry_snapshot_scope_trg
    on public.community_snapshot_registry;

create trigger validate_community_registry_snapshot_scope_trg
before insert or update on public.community_snapshot_registry
for each row execute function public.validate_community_registry_snapshot_scope();

create or replace function public.guard_community_snapshot_update()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
    if tg_op = 'DELETE' then
        raise exception using
            errcode = '55000',
            message = 'COMMUNITY_SNAPSHOT_APPEND_ONLY';
    end if;

    if old.status in ('ready','frozen','archived') then
        if old.status = 'ready'
           and new.status in ('frozen','archived')
           and new.fantagol_round_id = old.fantagol_round_id
           and new.snapshot_version = old.snapshot_version
           and new.phase = old.phase
           and new.source_prediction_count = old.source_prediction_count
           and new.source_member_count = old.source_member_count
           and new.source_league_count = old.source_league_count
           and new.source_match_count = old.source_match_count
           and new.eligible_prediction_count = old.eligible_prediction_count
           and new.excluded_prediction_count = old.excluded_prediction_count
           and new.quality_status = old.quality_status
           and new.quality_score = old.quality_score
           and new.minimum_sample_satisfied = old.minimum_sample_satisfied
           and new.input_hash = old.input_hash
           and new.output_hash = old.output_hash
           and new.engine_version = old.engine_version
           and new.snapshot_schema_version = old.snapshot_schema_version
           and new.requested_at = old.requested_at
           and new.built_at = old.built_at
           and new.metadata = old.metadata then
            return new;
        end if;

        raise exception using
            errcode = '55000',
            message = 'COMMUNITY_SNAPSHOT_IMMUTABLE';
    end if;

    if old.status = 'building' and new.status not in ('building','ready','failed') then
        raise exception using
            errcode = '55000',
            message = 'COMMUNITY_SNAPSHOT_INVALID_TRANSITION';
    end if;

    return new;
end;
$$;

drop trigger if exists guard_community_snapshot_update_trg
    on public.community_snapshots;

create trigger guard_community_snapshot_update_trg
before update or delete on public.community_snapshots
for each row execute function public.guard_community_snapshot_update();

create or replace function public.guard_community_child_immutable()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
    v_snapshot_id uuid;
    v_status text;
begin
    if tg_op = 'DELETE' then
        raise exception using
            errcode = '55000',
            message = 'COMMUNITY_ANALYTICS_APPEND_ONLY';
    end if;

    v_snapshot_id := case
        when tg_table_name in ('community_match_snapshots','community_exact_distributions','community_insights')
            then old.community_snapshot_id
        else null
    end;

    if v_snapshot_id is not null then
        select status into v_status
          from public.community_snapshots
         where id = v_snapshot_id;

        if v_status in ('ready','frozen','archived') then
            raise exception using
                errcode = '55000',
                message = 'COMMUNITY_ANALYTICS_IMMUTABLE';
        end if;
    end if;

    if tg_op = 'UPDATE' then
        raise exception using
            errcode = '55000',
            message = 'COMMUNITY_ANALYTICS_APPEND_ONLY';
    end if;

    return old;
end;
$$;

drop trigger if exists guard_community_match_snapshots_immutable_trg
    on public.community_match_snapshots;
create trigger guard_community_match_snapshots_immutable_trg
before update or delete on public.community_match_snapshots
for each row execute function public.guard_community_child_immutable();

drop trigger if exists guard_community_exact_distributions_immutable_trg
    on public.community_exact_distributions;
create trigger guard_community_exact_distributions_immutable_trg
before update or delete on public.community_exact_distributions
for each row execute function public.guard_community_child_immutable();

drop trigger if exists guard_community_insights_immutable_trg
    on public.community_insights;
create trigger guard_community_insights_immutable_trg
before update or delete on public.community_insights
for each row execute function public.guard_community_child_immutable();

create or replace function public.guard_community_append_only()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
    raise exception using
        errcode = '55000',
        message = 'COMMUNITY_EVENT_OR_TREND_APPEND_ONLY';
end;
$$;

drop trigger if exists guard_community_trends_append_only_trg
    on public.community_trends;
create trigger guard_community_trends_append_only_trg
before update or delete on public.community_trends
for each row execute function public.guard_community_append_only();

drop trigger if exists guard_community_snapshot_events_append_only_trg
    on public.community_snapshot_events;
create trigger guard_community_snapshot_events_append_only_trg
before update or delete on public.community_snapshot_events
for each row execute function public.guard_community_append_only();

-- ============================================================================
-- 5. BUILDER RPC
-- ============================================================================

create or replace function public.build_community_snapshot_rpc(
    p_fantagol_round_id uuid,
    p_phase text,
    p_engine_version text default 'community-intelligence-v1',
    p_correlation_id uuid default null,
    p_force_rebuild boolean default false
)
returns table (
    snapshot_id uuid,
    snapshot_version integer,
    phase text,
    status text,
    prediction_count integer,
    member_count integer,
    league_count integer,
    match_count integer,
    quality_status text,
    input_hash text,
    output_hash text,
    created boolean,
    idempotent boolean
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_registry public.community_snapshot_registry%rowtype;
    v_round public.fantagol_rounds%rowtype;
    v_snapshot_id uuid;
    v_snapshot_version integer;
    v_input_hash text;
    v_output_hash text;
    v_source_prediction_count integer;
    v_source_member_count integer;
    v_source_league_count integer;
    v_source_match_count integer;
    v_eligible_prediction_count integer;
    v_excluded_prediction_count integer;
    v_match_coverage numeric;
    v_quality_status text;
    v_quality_score numeric;
    v_minimum_sample_satisfied boolean;
    v_previous_snapshot_id uuid;
    v_match record;
    v_exact record;
    v_existing public.community_snapshots%rowtype;
    v_lock_key bigint;
begin
    if p_fantagol_round_id is null then
        raise exception using message = 'COMMUNITY_ROUND_NOT_FOUND';
    end if;

    if p_phase not in ('pre_live','lock','live','post_live','historical') then
        raise exception using message = 'COMMUNITY_INVALID_PHASE';
    end if;

    select * into v_round
      from public.fantagol_rounds
     where id = p_fantagol_round_id;

    if not found then
        raise exception using message = 'COMMUNITY_ROUND_NOT_FOUND';
    end if;

    v_lock_key := hashtextextended(
        p_fantagol_round_id::text || ':' || p_phase,
        0
    );

    if not pg_try_advisory_xact_lock(v_lock_key) then
        raise exception using message = 'COMMUNITY_SNAPSHOT_BUILD_IN_PROGRESS';
    end if;

    insert into public.community_snapshot_registry (
        fantagol_round_id,
        current_phase,
        status,
        last_requested_at
    )
    values (
        p_fantagol_round_id,
        p_phase,
        'building',
        clock_timestamp()
    )
    on conflict (fantagol_round_id)
    do update set
        current_phase = excluded.current_phase,
        status = 'building',
        last_requested_at = excluded.last_requested_at,
        updated_at = clock_timestamp()
    returning * into v_registry;

    insert into public.community_snapshot_events (
        fantagol_round_id,
        event_type,
        status,
        payload,
        correlation_id
    )
    values (
        p_fantagol_round_id,
        'snapshot_requested',
        'received',
        jsonb_build_object(
            'phase', p_phase,
            'engine_version', p_engine_version,
            'force_rebuild', p_force_rebuild
        ),
        p_correlation_id
    );

    select count(*)
      into v_source_match_count
      from public.fantagol_round_matches frm
     where frm.fantagol_round_id = p_fantagol_round_id
       and frm.removed_at is null;

    if v_source_match_count = 0 then
        update public.community_snapshot_registry
           set status = 'failed',
               last_failed_at = clock_timestamp()
         where fantagol_round_id = p_fantagol_round_id;

        raise exception using message = 'COMMUNITY_MATCH_SET_EMPTY';
    end if;

    with source_predictions as (
        select
            p.id,
            p.league_id,
            p.league_round_id,
            p.league_member_id,
            p.match_id,
            p.home_prediction,
            p.away_prediction,
            p.status,
            p.version,
            p.updated_at,
            p.submitted_at,
            p.locked_at
        from public.predictions p
        join public.league_rounds lr
          on lr.id = p.league_round_id
        join public.fantagol_round_matches frm
          on frm.fantagol_round_id = lr.fantagol_round_id
         and frm.match_id = p.match_id
         and frm.removed_at is null
        where lr.fantagol_round_id = p_fantagol_round_id
    ),
    eligible as (
        select *
          from source_predictions
         where status in ('submitted','locked')
           and league_round_id is not null
           and league_member_id is not null
           and home_prediction between 0 and 9
           and away_prediction between 0 and 9
    )
    select
        (select count(*) from source_predictions),
        (select count(distinct league_member_id) from eligible),
        (select count(distinct league_id) from eligible),
        (select count(*) from eligible),
        (select count(*) from source_predictions) - (select count(*) from eligible)
    into
        v_source_prediction_count,
        v_source_member_count,
        v_source_league_count,
        v_eligible_prediction_count,
        v_excluded_prediction_count;

    if v_eligible_prediction_count = 0 then
        update public.community_snapshot_registry
           set status = 'failed',
               last_failed_at = clock_timestamp()
         where fantagol_round_id = p_fantagol_round_id;

        insert into public.community_snapshot_events (
            fantagol_round_id,
            event_type,
            status,
            payload,
            correlation_id
        )
        values (
            p_fantagol_round_id,
            'snapshot_build_failed',
            'failed',
            jsonb_build_object('error_code','COMMUNITY_NO_ELIGIBLE_PREDICTIONS'),
            p_correlation_id
        );

        raise exception using message = 'COMMUNITY_NO_ELIGIBLE_PREDICTIONS';
    end if;

    select 100::numeric *
           count(distinct p.match_id)::numeric /
           nullif(v_source_match_count, 0)::numeric
      into v_match_coverage
      from public.predictions p
      join public.league_rounds lr on lr.id = p.league_round_id
     where lr.fantagol_round_id = p_fantagol_round_id
       and p.status in ('submitted','locked')
       and p.league_member_id is not null;

    v_quality_status := public.community_quality_status(
        v_eligible_prediction_count,
        v_source_member_count,
        v_source_league_count,
        coalesce(v_match_coverage,0)
    );

    v_quality_score := public.community_quality_score(
        v_eligible_prediction_count,
        v_source_member_count,
        v_source_league_count,
        coalesce(v_match_coverage,0)
    );

    v_minimum_sample_satisfied :=
        v_eligible_prediction_count >= 5
        and v_source_member_count >= 3
        and v_source_league_count >= 1;

    with canonical as (
        select jsonb_agg(
            jsonb_build_object(
                'prediction_id', p.id,
                'league_round_id', p.league_round_id,
                'league_member_id', p.league_member_id,
                'match_id', p.match_id,
                'home', p.home_prediction,
                'away', p.away_prediction,
                'status', p.status,
                'version', p.version
            )
            order by p.match_id, p.league_round_id, p.league_member_id
        ) as payload
        from public.predictions p
        join public.league_rounds lr on lr.id = p.league_round_id
        where lr.fantagol_round_id = p_fantagol_round_id
          and p.status in ('submitted','locked')
          and p.league_round_id is not null
          and p.league_member_id is not null
          and p.home_prediction between 0 and 9
          and p.away_prediction between 0 and 9
    )
    select encode(
        digest(
            coalesce(payload, '[]'::jsonb)::text
            || '|' || p_fantagol_round_id::text
            || '|' || p_phase
            || '|' || p_engine_version,
            'sha256'
        ),
        'hex'
    )
    into v_input_hash
    from canonical;

    if not p_force_rebuild then
        select *
          into v_existing
          from public.community_snapshots
         where fantagol_round_id = p_fantagol_round_id
           and phase = p_phase
           and input_hash = v_input_hash
           and engine_version = p_engine_version
           and snapshot_schema_version = 1
           and status in ('ready','frozen')
         order by snapshot_version desc
         limit 1;

        if found then
            return query
            select
                v_existing.id,
                v_existing.snapshot_version,
                v_existing.phase,
                v_existing.status,
                v_existing.eligible_prediction_count,
                v_existing.source_member_count,
                v_existing.source_league_count,
                v_existing.source_match_count,
                v_existing.quality_status,
                v_existing.input_hash,
                v_existing.output_hash,
                false,
                true;
            return;
        end if;
    end if;

    select coalesce(max(cs.snapshot_version), 0) + 1
      into v_snapshot_version
      from public.community_snapshots cs
     where cs.fantagol_round_id = p_fantagol_round_id;

    select current_snapshot_id
      into v_previous_snapshot_id
      from public.community_snapshot_registry
     where fantagol_round_id = p_fantagol_round_id;

    insert into public.community_snapshots (
        fantagol_round_id,
        snapshot_version,
        phase,
        status,
        source_prediction_count,
        source_member_count,
        source_league_count,
        source_match_count,
        eligible_prediction_count,
        excluded_prediction_count,
        quality_status,
        quality_score,
        minimum_sample_satisfied,
        input_hash,
        output_hash,
        engine_version,
        snapshot_schema_version,
        requested_at,
        metadata
    )
    values (
        p_fantagol_round_id,
        v_snapshot_version,
        p_phase,
        'building',
        v_source_prediction_count,
        v_source_member_count,
        v_source_league_count,
        v_source_match_count,
        v_eligible_prediction_count,
        v_excluded_prediction_count,
        v_quality_status,
        v_quality_score,
        v_minimum_sample_satisfied,
        v_input_hash,
        '',
        p_engine_version,
        1,
        clock_timestamp(),
        jsonb_build_object(
            'match_coverage', coalesce(v_match_coverage,0),
            'previous_snapshot_id', v_previous_snapshot_id
        )
    )
    returning id into v_snapshot_id;

    insert into public.community_snapshot_events (
        fantagol_round_id,
        community_snapshot_id,
        event_type,
        status,
        payload,
        correlation_id
    )
    values (
        p_fantagol_round_id,
        v_snapshot_id,
        'snapshot_build_started',
        'building',
        jsonb_build_object('snapshot_version', v_snapshot_version, 'phase', p_phase),
        p_correlation_id
    );

    for v_match in
        with eligible as (
            select
                p.league_id,
                p.league_member_id,
                p.match_id,
                p.home_prediction,
                p.away_prediction
            from public.predictions p
            join public.league_rounds lr on lr.id = p.league_round_id
            where lr.fantagol_round_id = p_fantagol_round_id
              and p.status in ('submitted','locked')
              and p.league_round_id is not null
              and p.league_member_id is not null
              and p.home_prediction between 0 and 9
              and p.away_prediction between 0 and 9
        ),
        aggregate_rows as (
            select
                frm.match_id,
                frm.slot_number,
                count(e.match_id)::integer as prediction_count,
                count(distinct e.league_member_id)::integer as member_count,
                count(distinct e.league_id)::integer as league_count,
                count(*) filter (where e.home_prediction > e.away_prediction)::integer as home_pick_count,
                count(*) filter (where e.home_prediction = e.away_prediction)::integer as draw_pick_count,
                count(*) filter (where e.home_prediction < e.away_prediction)::integer as away_pick_count,
                count(*) filter (where e.home_prediction + e.away_prediction >= 3)::integer as over_count,
                count(*) filter (where e.home_prediction + e.away_prediction < 3)::integer as under_count,
                count(*) filter (where e.home_prediction > 0 and e.away_prediction > 0)::integer as goal_count,
                count(*) filter (where not (e.home_prediction > 0 and e.away_prediction > 0))::integer as no_goal_count,
                coalesce(avg(e.home_prediction),0)::numeric as avg_home,
                coalesce(avg(e.away_prediction),0)::numeric as avg_away
            from public.fantagol_round_matches frm
            left join eligible e on e.match_id = frm.match_id
            where frm.fantagol_round_id = p_fantagol_round_id
              and frm.removed_at is null
            group by frm.match_id, frm.slot_number
        )
        select *,
            public.community_percentage(home_pick_count, prediction_count) as home_pct,
            public.community_percentage(draw_pick_count, prediction_count) as draw_pct,
            public.community_percentage(away_pick_count, prediction_count) as away_pct,
            public.community_percentage(over_count, prediction_count) as over_pct,
            public.community_percentage(under_count, prediction_count) as under_pct,
            public.community_percentage(goal_count, prediction_count) as goal_pct,
            public.community_percentage(no_goal_count, prediction_count) as no_goal_pct
        from aggregate_rows
        order by slot_number
    loop
        declare
            v_consensus_outcome text;
            v_consensus_percent numeric;
            v_confidence numeric;
            v_chaos numeric;
            v_exact_dispersion numeric;
            v_market_snapshot_id uuid;
            v_market_context jsonb := '{}'::jsonb;
            v_match_quality_status text;
            v_match_quality_score numeric;
        begin
            if v_match.prediction_count = 0 then
                v_consensus_outcome := null;
                v_consensus_percent := 0;
            elsif v_match.home_pct >= v_match.draw_pct and v_match.home_pct >= v_match.away_pct then
                v_consensus_outcome := '1';
                v_consensus_percent := v_match.home_pct;
            elsif v_match.draw_pct >= v_match.home_pct and v_match.draw_pct >= v_match.away_pct then
                v_consensus_outcome := 'X';
                v_consensus_percent := v_match.draw_pct;
            else
                v_consensus_outcome := '2';
                v_consensus_percent := v_match.away_pct;
            end if;

            v_confidence := public.community_confidence_index(
                v_match.home_pick_count,
                v_match.draw_pick_count,
                v_match.away_pick_count
            );
            v_chaos := 100 - v_confidence;

            select public.community_exact_dispersion_index(
                coalesce(array_agg(x.cnt::numeric order by x.cnt desc), array[]::numeric[])
            )
            into v_exact_dispersion
            from (
                select count(*)::integer as cnt
                from public.predictions p
                join public.league_rounds lr on lr.id = p.league_round_id
                where lr.fantagol_round_id = p_fantagol_round_id
                  and p.match_id = v_match.match_id
                  and p.status in ('submitted','locked')
                  and p.league_member_id is not null
                  and p.home_prediction between 0 and 9
                  and p.away_prediction between 0 and 9
                group by p.home_prediction, p.away_prediction
            ) x;

            select oms.odds_market_snapshot_id,
                   jsonb_build_object(
                       'market_available', true,
                       'official_snapshot_id', oms.id,
                       'odds_market_snapshot_id', oms.odds_market_snapshot_id,
                       'frozen_at', oms.frozen_at,
                       'policy_version', oms.policy_version,
                       'consensus', om.consensus_payload,
                       'quality', om.quality_payload,
                       'collected_at', om.collected_at
                   )
              into v_market_snapshot_id, v_market_context
              from public.official_match_odds_snapshots oms
              join public.odds_market_snapshots om
                on om.id = oms.odds_market_snapshot_id
             where oms.match_id = v_match.match_id
             limit 1;

            if v_market_snapshot_id is null then
                v_market_context := jsonb_build_object('market_available', false);
            end if;

            v_match_quality_status := public.community_quality_status(
                v_match.prediction_count,
                v_match.member_count,
                v_match.league_count,
                case when v_match.prediction_count > 0 then 100 else 0 end
            );
            v_match_quality_score := public.community_quality_score(
                v_match.prediction_count,
                v_match.member_count,
                v_match.league_count,
                case when v_match.prediction_count > 0 then 100 else 0 end
            );

            insert into public.community_match_snapshots (
                community_snapshot_id,
                fantagol_round_id,
                match_id,
                slot_number,
                prediction_count,
                member_count,
                league_count,
                home_pick_count,
                draw_pick_count,
                away_pick_count,
                home_pick_percent,
                draw_pick_percent,
                away_pick_percent,
                over_2_5_count,
                under_2_5_count,
                over_2_5_percent,
                under_2_5_percent,
                goal_count,
                no_goal_count,
                goal_percent,
                no_goal_percent,
                avg_home_goals,
                avg_away_goals,
                avg_total_goals,
                consensus_outcome,
                consensus_percent,
                consensus_index,
                confidence_index,
                chaos_index,
                exact_dispersion_index,
                sample_quality_status,
                sample_quality_score,
                market_snapshot_id,
                market_context
            )
            values (
                v_snapshot_id,
                p_fantagol_round_id,
                v_match.match_id,
                v_match.slot_number,
                v_match.prediction_count,
                v_match.member_count,
                v_match.league_count,
                v_match.home_pick_count,
                v_match.draw_pick_count,
                v_match.away_pick_count,
                v_match.home_pct,
                v_match.draw_pct,
                v_match.away_pct,
                v_match.over_count,
                v_match.under_count,
                v_match.over_pct,
                v_match.under_pct,
                v_match.goal_count,
                v_match.no_goal_count,
                v_match.goal_pct,
                v_match.no_goal_pct,
                v_match.avg_home,
                v_match.avg_away,
                v_match.avg_home + v_match.avg_away,
                v_consensus_outcome,
                v_consensus_percent,
                v_consensus_percent,
                v_confidence,
                v_chaos,
                coalesce(v_exact_dispersion,0),
                v_match_quality_status,
                v_match_quality_score,
                v_market_snapshot_id,
                v_market_context
            );

            if v_match.prediction_count > 0 then
                if v_confidence >= 70 then
                    insert into public.community_insights (
                        community_snapshot_id, match_id, scope, insight_code,
                        severity, priority, message_key, parameters
                    )
                    values (
                        v_snapshot_id, v_match.match_id, 'match',
                        'COMMUNITY_COMPACT', 'notable', 20,
                        'control_room.insight.community_compact',
                        jsonb_build_object('confidence_index', v_confidence)
                    );
                elsif v_confidence <= 35 then
                    insert into public.community_insights (
                        community_snapshot_id, match_id, scope, insight_code,
                        severity, priority, message_key, parameters
                    )
                    values (
                        v_snapshot_id, v_match.match_id, 'match',
                        'COMMUNITY_DIVIDED', 'notable', 20,
                        'control_room.insight.community_divided',
                        jsonb_build_object('confidence_index', v_confidence)
                    );
                end if;

                if v_chaos >= 65 then
                    insert into public.community_insights (
                        community_snapshot_id, match_id, scope, insight_code,
                        severity, priority, message_key, parameters
                    )
                    values (
                        v_snapshot_id, v_match.match_id, 'match',
                        'HIGH_UNCERTAINTY', 'high', 10,
                        'control_room.insight.high_uncertainty',
                        jsonb_build_object('chaos_index', v_chaos)
                    );
                end if;

                if coalesce(v_exact_dispersion,0) <= 35 then
                    insert into public.community_insights (
                        community_snapshot_id, match_id, scope, insight_code,
                        severity, priority, message_key, parameters
                    )
                    values (
                        v_snapshot_id, v_match.match_id, 'match',
                        'EXACT_CONCENTRATED', 'notable', 30,
                        'control_room.insight.exact_concentrated',
                        jsonb_build_object('exact_dispersion_index', v_exact_dispersion)
                    );
                elsif coalesce(v_exact_dispersion,0) >= 70 then
                    insert into public.community_insights (
                        community_snapshot_id, match_id, scope, insight_code,
                        severity, priority, message_key, parameters
                    )
                    values (
                        v_snapshot_id, v_match.match_id, 'match',
                        'EXACT_DISPERSED', 'notable', 30,
                        'control_room.insight.exact_dispersed',
                        jsonb_build_object('exact_dispersion_index', v_exact_dispersion)
                    );
                end if;
            end if;
        end;
    end loop;

    for v_exact in
        with eligible as (
            select
                p.match_id,
                p.home_prediction,
                p.away_prediction
            from public.predictions p
            join public.league_rounds lr on lr.id = p.league_round_id
            where lr.fantagol_round_id = p_fantagol_round_id
              and p.status in ('submitted','locked')
              and p.league_member_id is not null
              and p.home_prediction between 0 and 9
              and p.away_prediction between 0 and 9
        ),
        grouped as (
            select
                match_id,
                home_prediction,
                away_prediction,
                count(*)::integer as prediction_count
            from eligible
            group by match_id, home_prediction, away_prediction
        ),
        ranked as (
            select
                g.*,
                sum(g.prediction_count) over (partition by g.match_id)::integer as match_total,
                row_number() over (
                    partition by g.match_id
                    order by g.prediction_count desc, g.home_prediction, g.away_prediction
                )::integer as rank
            from grouped g
        )
        select *,
               public.community_percentage(prediction_count, match_total) as prediction_percent
        from ranked
        order by match_id, rank
    loop
        insert into public.community_exact_distributions (
            community_snapshot_id,
            match_id,
            home_prediction,
            away_prediction,
            prediction_count,
            prediction_percent,
            rank,
            is_top_exact
        )
        values (
            v_snapshot_id,
            v_exact.match_id,
            v_exact.home_prediction,
            v_exact.away_prediction,
            v_exact.prediction_count,
            v_exact.prediction_percent,
            v_exact.rank,
            v_exact.rank = 1
        );
    end loop;

    if v_previous_snapshot_id is not null then
        insert into public.community_trends (
            fantagol_round_id,
            match_id,
            from_snapshot_id,
            to_snapshot_id,
            window_code,
            metric_code,
            outcome_code,
            from_value,
            to_value,
            delta_value,
            delta_percent,
            direction,
            velocity,
            stability,
            momentum,
            late_shift
        )
        select
            p_fantagol_round_id,
            current_match.match_id,
            v_previous_snapshot_id,
            v_snapshot_id,
            'snapshot_to_snapshot',
            metric.metric_code,
            metric.outcome_code,
            metric.from_value,
            metric.to_value,
            metric.to_value - metric.from_value,
            case
                when metric.from_value = 0 then null
                else ((metric.to_value - metric.from_value) / abs(metric.from_value)) * 100
            end,
            case
                when abs(metric.to_value - metric.from_value) < 0.5 then 'stable'
                when metric.to_value > metric.from_value then 'rising'
                else 'falling'
            end,
            abs(metric.to_value - metric.from_value),
            greatest(0, 100 - abs(metric.to_value - metric.from_value)),
            case
                when abs(metric.to_value - metric.from_value) < 0.5 then 'stable'
                when metric.to_value > metric.from_value then 'rising'
                else 'falling'
            end,
            p_phase = 'lock'
                and v_round.lock_at - clock_timestamp() <= interval '6 hours'
        from public.community_match_snapshots current_match
        join public.community_match_snapshots previous_match
          on previous_match.community_snapshot_id = v_previous_snapshot_id
         and previous_match.match_id = current_match.match_id
        cross join lateral (
            values
                ('sign_share', current_match.consensus_outcome,
                    previous_match.consensus_percent, current_match.consensus_percent),
                ('confidence_index', null,
                    previous_match.confidence_index, current_match.confidence_index),
                ('chaos_index', null,
                    previous_match.chaos_index, current_match.chaos_index)
        ) metric(metric_code, outcome_code, from_value, to_value)
        where current_match.community_snapshot_id = v_snapshot_id;
    end if;

    select encode(
        digest(
            jsonb_build_object(
                'snapshot', (
                    select to_jsonb(cs)
                    from public.community_snapshots cs
                    where cs.id = v_snapshot_id
                ),
                'matches', (
                    select coalesce(jsonb_agg(to_jsonb(cms) order by cms.slot_number), '[]'::jsonb)
                    from public.community_match_snapshots cms
                    where cms.community_snapshot_id = v_snapshot_id
                ),
                'exact', (
                    select coalesce(jsonb_agg(to_jsonb(ced) order by ced.match_id, ced.rank), '[]'::jsonb)
                    from public.community_exact_distributions ced
                    where ced.community_snapshot_id = v_snapshot_id
                )
            )::text,
            'sha256'
        ),
        'hex'
    )
    into v_output_hash;

    update public.community_snapshots
       set status = case when p_phase = 'lock' then 'frozen' else 'ready' end,
           output_hash = v_output_hash,
           built_at = clock_timestamp(),
           frozen_at = case when p_phase = 'lock' then clock_timestamp() else null end
     where id = v_snapshot_id;

    update public.community_snapshot_registry
       set current_phase = p_phase,
           current_snapshot_id = v_snapshot_id,
           latest_pre_live_snapshot_id =
               case when p_phase = 'pre_live' then v_snapshot_id else latest_pre_live_snapshot_id end,
           lock_snapshot_id =
               case when p_phase = 'lock' then v_snapshot_id else lock_snapshot_id end,
           latest_live_snapshot_id =
               case when p_phase = 'live' then v_snapshot_id else latest_live_snapshot_id end,
           post_live_snapshot_id =
               case when p_phase = 'post_live' then v_snapshot_id else post_live_snapshot_id end,
           historical_snapshot_id =
               case when p_phase = 'historical' then v_snapshot_id else historical_snapshot_id end,
           status = case when p_phase = 'lock' then 'frozen' else 'ready' end,
           last_completed_at = clock_timestamp(),
           snapshot_count = snapshot_count + 1,
           updated_at = clock_timestamp()
     where fantagol_round_id = p_fantagol_round_id;

    insert into public.community_snapshot_events (
        fantagol_round_id,
        community_snapshot_id,
        event_type,
        status,
        payload,
        correlation_id
    )
    values (
        p_fantagol_round_id,
        v_snapshot_id,
        case when p_phase = 'lock' then 'snapshot_frozen' else 'snapshot_build_completed' end,
        case when p_phase = 'lock' then 'frozen' else 'ready' end,
        jsonb_build_object(
            'snapshot_version', v_snapshot_version,
            'prediction_count', v_eligible_prediction_count,
            'member_count', v_source_member_count,
            'league_count', v_source_league_count,
            'match_count', v_source_match_count,
            'quality_status', v_quality_status,
            'quality_score', v_quality_score,
            'input_hash', v_input_hash,
            'output_hash', v_output_hash
        ),
        p_correlation_id
    );

    return query
    select
        v_snapshot_id,
        v_snapshot_version,
        p_phase,
        case when p_phase = 'lock' then 'frozen' else 'ready' end,
        v_eligible_prediction_count,
        v_source_member_count,
        v_source_league_count,
        v_source_match_count,
        v_quality_status,
        v_input_hash,
        v_output_hash,
        true,
        false;
exception
    when others then
        if p_fantagol_round_id is not null then
            update public.community_snapshot_registry
               set status = 'failed',
                   last_failed_at = clock_timestamp()
             where fantagol_round_id = p_fantagol_round_id;

            insert into public.community_snapshot_events (
                fantagol_round_id,
                community_snapshot_id,
                event_type,
                status,
                payload,
                correlation_id
            )
            values (
                p_fantagol_round_id,
                v_snapshot_id,
                'snapshot_build_failed',
                'failed',
                jsonb_build_object(
                    'error_code', 'COMMUNITY_SNAPSHOT_BUILD_FAILED',
                    'message', sqlerrm,
                    'sqlstate', sqlstate
                ),
                p_correlation_id
            );
        end if;
        raise;
end;
$$;

create or replace function public.refresh_community_snapshot_rpc(
    p_fantagol_round_id uuid,
    p_engine_version text default 'community-intelligence-v1',
    p_correlation_id uuid default null
)
returns table (
    snapshot_id uuid,
    snapshot_version integer,
    phase text,
    status text,
    prediction_count integer,
    member_count integer,
    league_count integer,
    match_count integer,
    quality_status text,
    input_hash text,
    output_hash text,
    created boolean,
    idempotent boolean
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_round public.fantagol_rounds%rowtype;
    v_phase text;
begin
    select * into v_round
      from public.fantagol_rounds
     where id = p_fantagol_round_id;

    if not found then
        raise exception using message = 'COMMUNITY_ROUND_NOT_FOUND';
    end if;

    v_phase := case
        when v_round.status in ('predictions_open','scheduled','draft') then 'pre_live'
        when v_round.status = 'predictions_locked' then 'lock'
        when v_round.status in ('live','partial_finished','waiting_postponed') then 'live'
        when v_round.status in ('final_calculable','final_official','recalculated') then 'post_live'
        else 'pre_live'
    end;

    return query
    select *
    from public.build_community_snapshot_rpc(
        p_fantagol_round_id,
        v_phase,
        p_engine_version,
        p_correlation_id,
        false
    );
end;
$$;

create or replace function public.freeze_community_lock_snapshot_rpc(
    p_fantagol_round_id uuid,
    p_engine_version text default 'community-intelligence-v1',
    p_correlation_id uuid default null
)
returns table (
    snapshot_id uuid,
    snapshot_version integer,
    phase text,
    status text,
    prediction_count integer,
    member_count integer,
    league_count integer,
    match_count integer,
    quality_status text,
    input_hash text,
    output_hash text,
    created boolean,
    idempotent boolean
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_existing_id uuid;
begin
    select lock_snapshot_id
      into v_existing_id
      from public.community_snapshot_registry
     where fantagol_round_id = p_fantagol_round_id;

    if v_existing_id is not null then
        return query
        select
            cs.id,
            cs.snapshot_version,
            cs.phase,
            cs.status,
            cs.eligible_prediction_count,
            cs.source_member_count,
            cs.source_league_count,
            cs.source_match_count,
            cs.quality_status,
            cs.input_hash,
            cs.output_hash,
            false,
            true
        from public.community_snapshots cs
        where cs.id = v_existing_id;
        return;
    end if;

    return query
    select *
    from public.build_community_snapshot_rpc(
        p_fantagol_round_id,
        'lock',
        p_engine_version,
        p_correlation_id,
        false
    );
end;
$$;

-- ============================================================================
-- 6. READ MODELS
-- ============================================================================

create or replace view public.control_room_latest_snapshot_v
with (security_invoker = true)
as
select
    csr.fantagol_round_id,
    csr.current_phase,
    csr.status as registry_status,
    csr.current_snapshot_id,
    cs.snapshot_version,
    cs.phase,
    cs.status,
    cs.source_prediction_count,
    cs.source_member_count,
    cs.source_league_count,
    cs.source_match_count,
    cs.eligible_prediction_count,
    cs.excluded_prediction_count,
    cs.quality_status,
    cs.quality_score,
    cs.minimum_sample_satisfied,
    cs.input_hash,
    cs.output_hash,
    cs.engine_version,
    cs.built_at,
    cs.frozen_at,
    csr.last_completed_at,
    csr.next_refresh_at
from public.community_snapshot_registry csr
join public.community_snapshots cs
  on cs.id = csr.current_snapshot_id;

create or replace view public.control_room_match_v
with (security_invoker = true)
as
select
    cs.fantagol_round_id,
    cs.id as community_snapshot_id,
    cs.snapshot_version,
    cs.phase,
    cs.status as snapshot_status,
    cs.built_at,
    cms.match_id,
    cms.slot_number,
    m.kickoff,
    m.status as match_status,
    m.home_score,
    m.away_score,
    ht.id as home_team_id,
    ht.name as home_team_name,
    ht.short_name as home_team_short_name,
    ht.logo_url as home_team_logo_url,
    ht.crest_reference as home_team_crest_reference,
    at.id as away_team_id,
    at.name as away_team_name,
    at.short_name as away_team_short_name,
    at.logo_url as away_team_logo_url,
    at.crest_reference as away_team_crest_reference,
    cms.prediction_count,
    cms.member_count,
    cms.league_count,
    cms.home_pick_percent,
    cms.draw_pick_percent,
    cms.away_pick_percent,
    cms.over_2_5_percent,
    cms.under_2_5_percent,
    cms.goal_percent,
    cms.no_goal_percent,
    cms.avg_home_goals,
    cms.avg_away_goals,
    cms.avg_total_goals,
    cms.consensus_outcome,
    cms.consensus_percent,
    cms.consensus_index,
    cms.confidence_index,
    cms.chaos_index,
    cms.exact_dispersion_index,
    cms.sample_quality_status,
    cms.sample_quality_score,
    cms.market_snapshot_id,
    coalesce((cms.market_context->>'market_available')::boolean, false) as market_available,
    cms.market_context,
    cms.trend_context,
    (
        select coalesce(jsonb_agg(
            jsonb_build_object(
                'home_prediction', ced.home_prediction,
                'away_prediction', ced.away_prediction,
                'prediction_count', ced.prediction_count,
                'prediction_percent', ced.prediction_percent,
                'rank', ced.rank,
                'is_top_exact', ced.is_top_exact,
                'change_from_previous', ced.change_from_previous
            )
            order by ced.rank
        ), '[]'::jsonb)
        from public.community_exact_distributions ced
        where ced.community_snapshot_id = cs.id
          and ced.match_id = cms.match_id
    ) as exact_distribution,
    (
        select coalesce(jsonb_agg(
            jsonb_build_object(
                'insight_code', ci.insight_code,
                'severity', ci.severity,
                'priority', ci.priority,
                'message_key', ci.message_key,
                'parameters', ci.parameters
            )
            order by ci.priority, ci.created_at
        ), '[]'::jsonb)
        from public.community_insights ci
        where ci.community_snapshot_id = cs.id
          and ci.match_id = cms.match_id
    ) as insights
from public.community_snapshot_registry csr
join public.community_snapshots cs
  on cs.id = csr.current_snapshot_id
join public.community_match_snapshots cms
  on cms.community_snapshot_id = cs.id
join public.matches m
  on m.id = cms.match_id
join public.teams ht
  on ht.id = m.home_team_id
join public.teams at
  on at.id = m.away_team_id;

create or replace view public.control_room_exact_heatmap_v
with (security_invoker = true)
as
select
    cs.fantagol_round_id,
    ced.community_snapshot_id,
    cs.snapshot_version,
    cs.phase,
    ced.match_id,
    ced.home_prediction,
    ced.away_prediction,
    ced.prediction_count,
    ced.prediction_percent,
    ced.rank,
    ced.is_top_exact,
    ced.change_from_previous
from public.community_snapshot_registry csr
join public.community_snapshots cs
  on cs.id = csr.current_snapshot_id
join public.community_exact_distributions ced
  on ced.community_snapshot_id = cs.id;

create or replace view public.control_room_trend_v
with (security_invoker = true)
as
select
    ct.fantagol_round_id,
    ct.match_id,
    ct.from_snapshot_id,
    fs.snapshot_version as from_snapshot_version,
    ct.to_snapshot_id,
    ts.snapshot_version as to_snapshot_version,
    ct.window_code,
    ct.metric_code,
    ct.outcome_code,
    ct.from_value,
    ct.to_value,
    ct.delta_value,
    ct.delta_percent,
    ct.direction,
    ct.velocity,
    ct.stability,
    ct.momentum,
    ct.late_shift,
    ct.created_at
from public.community_trends ct
join public.community_snapshots fs on fs.id = ct.from_snapshot_id
join public.community_snapshots ts on ts.id = ct.to_snapshot_id;

create or replace view public.control_room_overview_v
with (security_invoker = true)
as
select
    fr.id as fantagol_round_id,
    fr.name as round_name,
    fr.sequence as round_sequence,
    fr.status as round_status,
    fr.opens_at,
    fr.lock_at,
    fr.starts_at,
    cs.id as community_snapshot_id,
    cs.snapshot_version,
    cs.phase,
    cs.status as snapshot_status,
    cs.built_at,
    cs.eligible_prediction_count as prediction_count,
    cs.source_member_count as member_count,
    cs.source_league_count as league_count,
    cs.source_match_count as match_count,
    cs.quality_status,
    cs.quality_score,
    cs.minimum_sample_satisfied,
    (
        select jsonb_build_object(
            'match_id', x.match_id,
            'slot_number', x.slot_number,
            'value', x.confidence_index
        )
        from public.community_match_snapshots x
        where x.community_snapshot_id = cs.id
          and x.prediction_count >= 5
        order by x.confidence_index desc, x.slot_number
        limit 1
    ) as safest_match,
    (
        select jsonb_build_object(
            'match_id', x.match_id,
            'slot_number', x.slot_number,
            'value', x.chaos_index
        )
        from public.community_match_snapshots x
        where x.community_snapshot_id = cs.id
        order by x.chaos_index desc, x.slot_number
        limit 1
    ) as most_uncertain_match,
    (
        select jsonb_build_object(
            'match_id', x.match_id,
            'slot_number', x.slot_number,
            'value', x.exact_dispersion_index
        )
        from public.community_match_snapshots x
        where x.community_snapshot_id = cs.id
          and x.prediction_count >= 5
        order by x.exact_dispersion_index asc, x.slot_number
        limit 1
    ) as most_concentrated_exact,
    (
        select jsonb_build_object(
            'match_id', t.match_id,
            'value', t.velocity,
            'metric_code', t.metric_code,
            'direction', t.direction
        )
        from public.community_trends t
        where t.to_snapshot_id = cs.id
        order by t.velocity desc, t.created_at desc
        limit 1
    ) as strongest_trend,
    (
        select count(distinct cms.market_snapshot_id)
        from public.community_match_snapshots cms
        where cms.community_snapshot_id = cs.id
          and cms.market_snapshot_id is not null
    )::integer as market_snapshot_count
from public.community_snapshot_registry csr
join public.community_snapshots cs
  on cs.id = csr.current_snapshot_id
join public.fantagol_rounds fr
  on fr.id = csr.fantagol_round_id;

-- ============================================================================
-- 7. CLIENT RPC
-- ============================================================================

create or replace function public.get_control_room_overview_rpc(
    p_fantagol_round_id uuid default null
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
    v_round_id uuid;
    v_payload jsonb;
begin
    if auth.uid() is null then
        raise exception using message = 'COMMUNITY_ACCESS_DENIED';
    end if;

    v_round_id := p_fantagol_round_id;

    if v_round_id is null then
        select csr.fantagol_round_id
          into v_round_id
          from public.community_snapshot_registry csr
          join public.community_snapshots cs on cs.id = csr.current_snapshot_id
          join public.fantagol_rounds fr on fr.id = csr.fantagol_round_id
         where fr.active = true
           and cs.status in ('ready','frozen')
         order by
             case
                 when fr.status in ('predictions_open','predictions_locked','live','partial_finished')
                     then 0
                 else 1
             end,
             fr.starts_at desc
         limit 1;
    end if;

    if v_round_id is null then
        return jsonb_build_object(
            'available', false,
            'error_code', 'COMMUNITY_ROUND_NOT_FOUND'
        );
    end if;

    select jsonb_build_object(
        'available', true,
        'overview', to_jsonb(o),
        'matches', (
            select coalesce(jsonb_agg(to_jsonb(mv) order by mv.slot_number), '[]'::jsonb)
            from public.control_room_match_v mv
            where mv.fantagol_round_id = v_round_id
        )
    )
    into v_payload
    from public.control_room_overview_v o
    where o.fantagol_round_id = v_round_id;

    return coalesce(
        v_payload,
        jsonb_build_object(
            'available', false,
            'error_code', 'COMMUNITY_SNAPSHOT_UNAVAILABLE'
        )
    );
end;
$$;

create or replace function public.get_control_room_match_rpc(
    p_fantagol_round_id uuid,
    p_match_id uuid
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
    v_payload jsonb;
begin
    if auth.uid() is null then
        raise exception using message = 'COMMUNITY_ACCESS_DENIED';
    end if;

    select jsonb_build_object(
        'available', true,
        'match', to_jsonb(mv),
        'heatmap', (
            select coalesce(jsonb_agg(to_jsonb(h) order by h.rank), '[]'::jsonb)
            from public.control_room_exact_heatmap_v h
            where h.fantagol_round_id = p_fantagol_round_id
              and h.match_id = p_match_id
        ),
        'trend', (
            select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at), '[]'::jsonb)
            from public.control_room_trend_v t
            where t.fantagol_round_id = p_fantagol_round_id
              and t.match_id = p_match_id
        )
    )
    into v_payload
    from public.control_room_match_v mv
    where mv.fantagol_round_id = p_fantagol_round_id
      and mv.match_id = p_match_id;

    return coalesce(
        v_payload,
        jsonb_build_object(
            'available', false,
            'error_code', 'COMMUNITY_MATCH_SNAPSHOT_UNAVAILABLE'
        )
    );
end;
$$;

create or replace function public.get_control_room_trend_rpc(
    p_fantagol_round_id uuid,
    p_match_id uuid default null,
    p_metric_code text default null
)
returns setof public.control_room_trend_v
language sql
security definer
stable
set search_path = public, pg_temp
as $$
    select *
    from public.control_room_trend_v t
    where auth.uid() is not null
      and t.fantagol_round_id = p_fantagol_round_id
      and (p_match_id is null or t.match_id = p_match_id)
      and (p_metric_code is null or t.metric_code = p_metric_code)
    order by t.created_at, t.match_id, t.metric_code
$$;

create or replace function public.get_community_snapshot_status_rpc(
    p_fantagol_round_id uuid
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
    v_payload jsonb;
begin
    if auth.uid() is null then
        raise exception using message = 'COMMUNITY_ACCESS_DENIED';
    end if;

    select jsonb_build_object(
        'registry', to_jsonb(csr),
        'current_snapshot', to_jsonb(cs),
        'recent_events', (
            select coalesce(jsonb_agg(to_jsonb(e) order by e.occurred_at desc), '[]'::jsonb)
            from (
                select
                    cse.event_type,
                    cse.status,
                    cse.payload,
                    cse.correlation_id,
                    cse.occurred_at
                from public.community_snapshot_events cse
                where cse.fantagol_round_id = p_fantagol_round_id
                order by cse.occurred_at desc
                limit 25
            ) e
        )
    )
    into v_payload
    from public.community_snapshot_registry csr
    left join public.community_snapshots cs
      on cs.id = csr.current_snapshot_id
    where csr.fantagol_round_id = p_fantagol_round_id;

    return coalesce(
        v_payload,
        jsonb_build_object(
            'available', false,
            'error_code', 'COMMUNITY_ROUND_NOT_FOUND'
        )
    );
end;
$$;

-- ============================================================================
-- 8. RLS
-- ============================================================================

alter table public.community_snapshot_registry enable row level security;
alter table public.community_snapshots enable row level security;
alter table public.community_match_snapshots enable row level security;
alter table public.community_exact_distributions enable row level security;
alter table public.community_trends enable row level security;
alter table public.community_insights enable row level security;
alter table public.community_snapshot_events enable row level security;

drop policy if exists community_snapshot_registry_service_all
    on public.community_snapshot_registry;
create policy community_snapshot_registry_service_all
    on public.community_snapshot_registry
    for all
    to service_role
    using (true)
    with check (true);

drop policy if exists community_snapshots_service_all
    on public.community_snapshots;
create policy community_snapshots_service_all
    on public.community_snapshots
    for all
    to service_role
    using (true)
    with check (true);

drop policy if exists community_match_snapshots_service_all
    on public.community_match_snapshots;
create policy community_match_snapshots_service_all
    on public.community_match_snapshots
    for all
    to service_role
    using (true)
    with check (true);

drop policy if exists community_exact_distributions_service_all
    on public.community_exact_distributions;
create policy community_exact_distributions_service_all
    on public.community_exact_distributions
    for all
    to service_role
    using (true)
    with check (true);

drop policy if exists community_trends_service_all
    on public.community_trends;
create policy community_trends_service_all
    on public.community_trends
    for all
    to service_role
    using (true)
    with check (true);

drop policy if exists community_insights_service_all
    on public.community_insights;
create policy community_insights_service_all
    on public.community_insights
    for all
    to service_role
    using (true)
    with check (true);

drop policy if exists community_snapshot_events_service_all
    on public.community_snapshot_events;
create policy community_snapshot_events_service_all
    on public.community_snapshot_events
    for all
    to service_role
    using (true)
    with check (true);

-- No direct client policies are intentionally created.

-- ============================================================================
-- 9. GRANTS
-- ============================================================================

revoke all on table public.community_snapshot_registry from anon, authenticated;
revoke all on table public.community_snapshots from anon, authenticated;
revoke all on table public.community_match_snapshots from anon, authenticated;
revoke all on table public.community_exact_distributions from anon, authenticated;
revoke all on table public.community_trends from anon, authenticated;
revoke all on table public.community_insights from anon, authenticated;
revoke all on table public.community_snapshot_events from anon, authenticated;

revoke all on public.control_room_latest_snapshot_v from anon, authenticated;
revoke all on public.control_room_overview_v from anon, authenticated;
revoke all on public.control_room_match_v from anon, authenticated;
revoke all on public.control_room_exact_heatmap_v from anon, authenticated;
revoke all on public.control_room_trend_v from anon, authenticated;

grant select, insert, update, delete on table public.community_snapshot_registry to service_role;
grant select, insert, update, delete on table public.community_snapshots to service_role;
grant select, insert, update, delete on table public.community_match_snapshots to service_role;
grant select, insert, update, delete on table public.community_exact_distributions to service_role;
grant select, insert, update, delete on table public.community_trends to service_role;
grant select, insert, update, delete on table public.community_insights to service_role;
grant select, insert, update, delete on table public.community_snapshot_events to service_role;

revoke all on function public.build_community_snapshot_rpc(uuid,text,text,uuid,boolean)
    from public, anon, authenticated;
revoke all on function public.refresh_community_snapshot_rpc(uuid,text,uuid)
    from public, anon, authenticated;
revoke all on function public.freeze_community_lock_snapshot_rpc(uuid,text,uuid)
    from public, anon, authenticated;

grant execute on function public.build_community_snapshot_rpc(uuid,text,text,uuid,boolean)
    to service_role;
grant execute on function public.refresh_community_snapshot_rpc(uuid,text,uuid)
    to service_role;
grant execute on function public.freeze_community_lock_snapshot_rpc(uuid,text,uuid)
    to service_role;

revoke all on function public.get_control_room_overview_rpc(uuid)
    from public, anon;
revoke all on function public.get_control_room_match_rpc(uuid,uuid)
    from public, anon;
revoke all on function public.get_control_room_trend_rpc(uuid,uuid,text)
    from public, anon;
revoke all on function public.get_community_snapshot_status_rpc(uuid)
    from public, anon;

grant execute on function public.get_control_room_overview_rpc(uuid)
    to authenticated, service_role;
grant execute on function public.get_control_room_match_rpc(uuid,uuid)
    to authenticated, service_role;
grant execute on function public.get_control_room_trend_rpc(uuid,uuid,text)
    to authenticated, service_role;
grant execute on function public.get_community_snapshot_status_rpc(uuid)
    to authenticated, service_role;

-- ============================================================================
-- 10. COMMENTS
-- ============================================================================

comment on table public.community_snapshot_registry is
'Operational registry for the current Community Intelligence snapshot of each FantaGol Round.';

comment on table public.community_snapshots is
'Immutable and versioned global anonymous Community Intelligence snapshots.';

comment on table public.community_match_snapshots is
'Anonymous per-match community consensus and derived indicators for one snapshot.';

comment on table public.community_exact_distributions is
'Exact-score distribution rows used by Top Exact and heatmap views.';

comment on table public.community_trends is
'Append-only deltas between Community Intelligence snapshots.';

comment on table public.community_insights is
'Rule-based descriptive insights. Never prescriptive betting advice.';

comment on table public.community_snapshot_events is
'Append-only operational timeline for Community Intelligence builds and lifecycle events.';

comment on function public.build_community_snapshot_rpc(uuid,text,text,uuid,boolean) is
'Builds an immutable, idempotent global anonymous Community Intelligence snapshot. Service role only.';

comment on function public.get_control_room_overview_rpc(uuid) is
'Returns the preaggregated Control Room overview without exposing individual predictions or identities.';

-- ============================================================================
-- 11. INSTALLATION VERIFICATION
-- ============================================================================

do $$
declare
    v_missing text[];
begin
    select array_agg(required_name)
      into v_missing
      from (
        values
            ('community_snapshot_registry'),
            ('community_snapshots'),
            ('community_match_snapshots'),
            ('community_exact_distributions'),
            ('community_trends'),
            ('community_insights'),
            ('community_snapshot_events')
      ) required(required_name)
     where to_regclass('public.' || required_name) is null;

    if v_missing is not null then
        raise exception
            'COMMUNITY_FOUNDATION_INSTALLATION_INCOMPLETE: %',
            array_to_string(v_missing, ', ');
    end if;
end;
$$;

commit;

-- ============================================================================
-- POST-INSTALL PROFORMA (execute manually after \i)
-- ============================================================================
--
-- 1. Objects
-- select table_name
-- from information_schema.tables
-- where table_schema = 'public'
--   and table_name like 'community_%'
-- order by table_name;
--
-- 2. RLS
-- select schemaname, tablename, rowsecurity
-- from pg_tables
-- where schemaname = 'public'
--   and tablename like 'community_%'
-- order by tablename;
--
-- 3. Build current test round
-- select *
-- from public.build_community_snapshot_rpc(
--     '<FANTAGOL_ROUND_ID>'::uuid,
--     'pre_live',
--     'community-intelligence-v1',
--     gen_random_uuid(),
--     false
-- );
--
-- 4. Idempotency
-- Repeat query 3. Expected: created = false, idempotent = true.
--
-- 5. Anonymous read model
-- select *
-- from public.control_room_overview_v
-- where fantagol_round_id = '<FANTAGOL_ROUND_ID>'::uuid;
--
-- 6. No private columns in read model
-- select column_name
-- from information_schema.columns
-- where table_schema = 'public'
--   and table_name in (
--       'control_room_overview_v',
--       'control_room_match_v',
--       'control_room_exact_heatmap_v',
--       'control_room_trend_v'
--   )
--   and column_name in ('user_id','league_id','league_member_id');
-- Expected: 0 rows.
--
-- 7. Immutability
-- update public.community_snapshots
-- set quality_score = 99
-- where status in ('ready','frozen')
-- limit 1;
-- Expected: COMMUNITY_SNAPSHOT_IMMUTABLE.
-- ============================================================================
