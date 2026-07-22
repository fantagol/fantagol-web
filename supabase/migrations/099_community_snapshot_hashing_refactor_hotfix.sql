-- ============================================================================
-- FANTAGOL
-- Migration 099: Community Snapshot Hashing Refactor Hotfix
-- Extracts SHA-256 hashing into a dedicated helper, resolves the Supabase
-- pgcrypto schema contract, and recompiles public.build_community_snapshot_rpc().
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- Dedicated hashing primitive
-- Supabase installs pgcrypto in the extensions schema. Keeping the namespace
-- explicit prevents SECURITY DEFINER/search_path resolution failures.
-- --------------------------------------------------------------------------
create or replace function public.community_sha256_hex(p_value text)
returns text
language sql
immutable
strict
parallel safe
set search_path = public, extensions, pg_temp
as $$
    select encode(
        extensions.digest(
            convert_to(p_value, 'UTF8'),
            'sha256'::text
        ),
        'hex'
    );
$$;

comment on function public.community_sha256_hex(text) is
'Canonical Community Intelligence SHA-256 helper. Uses extensions.digest explicitly so hashing remains independent from caller search_path.';

revoke all on function public.community_sha256_hex(text) from public;
grant execute on function public.community_sha256_hex(text) to service_role;

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
#variable_conflict use_column
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
    select public.community_sha256_hex(
        coalesce(canonical.payload, '[]'::jsonb)::text
        || '|' || p_fantagol_round_id::text
        || '|' || p_phase
        || '|' || p_engine_version
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

    select public.community_sha256_hex(
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
        )::text
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

comment on function public.build_community_snapshot_rpc(uuid, text, text, uuid, boolean) is
'Community Intelligence snapshot builder. Migration 099 preserves the 098 ambiguity fix and delegates canonical SHA-256 hashing to public.community_sha256_hex(text).';

do $$
declare
    v_builder_definition text;
    v_hash_definition text;
    v_probe text;
begin
    select pg_get_functiondef(p.oid)
      into v_builder_definition
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname = 'build_community_snapshot_rpc'
       and pg_get_function_identity_arguments(p.oid) =
           'p_fantagol_round_id uuid, p_phase text, p_engine_version text, p_correlation_id uuid, p_force_rebuild boolean';

    if v_builder_definition is null then
        raise exception 'COMMUNITY_BUILDER_099_FUNCTION_NOT_FOUND';
    end if;

    if position('#variable_conflict use_column' in v_builder_definition) = 0 then
        raise exception 'COMMUNITY_BUILDER_099_CONFLICT_DIRECTIVE_MISSING';
    end if;

    if position('public.community_sha256_hex' in v_builder_definition) = 0 then
        raise exception 'COMMUNITY_BUILDER_099_HASH_HELPER_NOT_USED';
    end if;

    select pg_get_functiondef(p.oid)
      into v_hash_definition
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname = 'community_sha256_hex'
       and pg_get_function_identity_arguments(p.oid) = 'p_value text';

    if v_hash_definition is null then
        raise exception 'COMMUNITY_BUILDER_099_HASH_HELPER_NOT_FOUND';
    end if;

    if position('extensions.digest' in v_hash_definition) = 0 then
        raise exception 'COMMUNITY_BUILDER_099_PGCRYPTO_NAMESPACE_NOT_EXPLICIT';
    end if;

    select public.community_sha256_hex('fantagol-community-hash-probe')
      into v_probe;

    if v_probe is null or length(v_probe) <> 64 then
        raise exception 'COMMUNITY_BUILDER_099_HASH_PROBE_FAILED';
    end if;
end;
$$;

commit;
