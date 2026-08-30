-- ============================================================================
-- FANTAGOL
-- MIGRATION 288
-- PREDICTION RECOVERY ADMIN STATUS CURRENT-FUTURE AUTHORITY
--
-- PRODUCT CONTRACT
-- - Prediction Recovery remains Punti Puri / Predictions only.
-- - The League Admin may arm a Recovery cycle at most once per League Round.
-- - After the first arming, technical Recovery windows are automatic.
-- - "Missing" means CURRENT/FUTURE missing official Predictions only.
-- - Historical unrecoverable holes must never re-enable the Admin CTA.
-- - Any existing prediction_recovery_cycles row makes manual re-arming false.
-- - Frontend state remains:
--     can_open=true                  => "Riapri pronostici"
--     can_open=false + missing>0 +
--       prior authorization exists  => "Attesa pronostici mancanti"
--     missing=0                     => "Pronostici bloccati"
-- ============================================================================

create or replace function public.get_prediction_recovery_admin_status_rpc(
    p_league_round_id uuid
)
returns table (
    league_id uuid,
    league_round_id uuid,
    league_round_status text,

    caller_member_id uuid,
    caller_role text,
    caller_is_admin boolean,

    active_member_count integer,
    delivered_member_count integer,
    missing_member_count integer,

    required_match_count integer,
    recoverable_match_count integer,
    started_or_unrecoverable_match_count integer,

    recovery_available boolean,
    can_open_recovery boolean,

    existing_authorization_count integer,

    last_recoverable_kickoff timestamptz
)
language plpgsql
stable
security definer
set search_path to public, pg_temp
as $function$
declare
    v_user_id uuid := auth.uid();
    v_league_id uuid;
    v_round_status text;

    v_caller_member_id uuid;
    v_caller_role text;

    v_active_member_count integer := 0;
    v_missing_member_count integer := 0;
    v_delivered_member_count integer := 0;

    v_required_match_count integer := 0;
    v_recoverable_match_count integer := 0;
    v_unrecoverable_count integer := 0;

    v_existing_authorization_count integer := 0;
    v_cycle_exists boolean := false;

    v_last_recoverable_kickoff timestamptz;

    v_recovery_available boolean := false;
    v_can_open boolean := false;

    v_now timestamptz := clock_timestamp();
begin
    if v_user_id is null then
        raise exception using
            errcode = 'P0001',
            message = 'AUTH_REQUIRED';
    end if;

    select
        lr.league_id,
        lr.status
    into
        v_league_id,
        v_round_status
    from public.league_rounds lr
    where lr.id = p_league_round_id
      and lr.enabled;

    if v_league_id is null then
        raise exception using
            errcode = 'P0001',
            message = 'LEAGUE_ROUND_NOT_FOUND';
    end if;

    select
        lm.id,
        lm.role
    into
        v_caller_member_id,
        v_caller_role
    from public.league_members lm
    where lm.league_id = v_league_id
      and lm.user_id = v_user_id
      and lm.status = 'active'
    order by
        case when lm.role = 'admin' then 0
             when lm.role = 'vice' then 1
             else 2
        end,
        lm.id
    limit 1;

    if v_caller_member_id is null then
        raise exception using
            errcode = 'P0001',
            message = 'LEAGUE_MEMBER_REQUIRED';
    end if;

    select count(*)::integer
    into v_active_member_count
    from public.league_members lm
    where lm.league_id = v_league_id
      and lm.status = 'active';

    /*
     * CURRENT/FUTURE authority.
     *
     * A member is missing only when at least one CURRENTLY RECOVERABLE
     * required match lacks an official submitted/locked Prediction.
     * Historical holes on already-started matches are intentionally ignored.
     */
    select count(*)::integer
    into v_missing_member_count
    from public.league_members lm
    where lm.league_id = v_league_id
      and lm.status = 'active'
      and public.member_needs_prediction_recovery_internal(
          p_league_round_id,
          lm.id,
          v_now
      );

    v_delivered_member_count :=
        greatest(v_active_member_count - v_missing_member_count, 0);

    select
        count(*)::integer,
        count(*) filter (where scope.recoverable)::integer,
        count(*) filter (where not scope.recoverable)::integer,
        min(scope.kickoff) filter (where scope.recoverable)
    into
        v_required_match_count,
        v_recoverable_match_count,
        v_unrecoverable_count,
        v_last_recoverable_kickoff
    from public.get_prediction_recovery_match_scope_internal(
        p_league_round_id,
        v_now
    ) scope;

    /*
     * Keep this counter historical, not only OPEN.
     * The frontend uses >0 to render the post-arming waiting state.
     */
    select count(*)::integer
    into v_existing_authorization_count
    from public.prediction_recovery_authorizations pra
    where pra.league_round_id = p_league_round_id;

    /*
     * One Admin consent per League Round.
     * ACTIVE / COMPLETED / REVOKED all mean "already armed once".
     */
    select exists (
        select 1
        from public.prediction_recovery_cycles prc
        where prc.league_round_id = p_league_round_id
    )
    into v_cycle_exists;

    v_recovery_available :=
        v_round_status in (
            'predictions_locked',
            'live',
            'waiting_postponed'
        )
        and v_missing_member_count > 0
        and v_recoverable_match_count > 0
        and not public.has_active_prediction_recovery_live_phase_internal(
            p_league_round_id
        );

    v_can_open :=
        v_caller_role = 'admin'
        and v_recovery_available
        and not v_cycle_exists;

    return query
    select
        v_league_id,
        p_league_round_id,
        v_round_status,

        v_caller_member_id,
        v_caller_role,
        v_caller_role = 'admin',

        v_active_member_count,
        v_delivered_member_count,
        v_missing_member_count,

        v_required_match_count,
        v_recoverable_match_count,
        v_unrecoverable_count,

        v_recovery_available,
        v_can_open,

        v_existing_authorization_count,

        v_last_recoverable_kickoff;
end;
$function$;

comment on function
public.get_prediction_recovery_admin_status_rpc(uuid)
is
'Authenticated Prediction Recovery admin read model using current/future Prediction need. Historical unrecoverable holes never re-enable Recovery. Any existing Recovery cycle row permanently prevents a second Admin arming for the League Round.';

revoke all on function
public.get_prediction_recovery_admin_status_rpc(uuid)
from public, anon;

grant execute on function
public.get_prediction_recovery_admin_status_rpc(uuid)
to authenticated, service_role;

do $verify$
declare
    v_def text;
begin
    select pg_get_functiondef(
        'public.get_prediction_recovery_admin_status_rpc(uuid)'::regprocedure
    )
    into v_def;

    if v_def is null then
        raise exception 'MIGRATION_288_ADMIN_STATUS_MISSING';
    end if;

    if position(
        'member_needs_prediction_recovery_internal'
        in lower(v_def)
    ) = 0 then
        raise exception 'MIGRATION_288_CURRENT_FUTURE_NEED_MISSING';
    end if;

    if position(
        'prediction_recovery_cycles'
        in lower(v_def)
    ) = 0 then
        raise exception 'MIGRATION_288_ONE_SHOT_CYCLE_GATE_MISSING';
    end if;

    if position(
        'has_complete_official_prediction_grid_internal'
        in lower(v_def)
    ) > 0 then
        raise exception 'MIGRATION_288_LEGACY_FULL_GRID_AUTHORITY_SURVIVED';
    end if;
end;
$verify$;