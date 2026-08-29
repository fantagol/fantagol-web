-- =====================================================================
-- FANTAGOL - MIGRATION 282
-- PREDICTION RECOVERY RESUBMIT AUTHORITY
-- Points Pure / Predictions only
--
-- Contract:
-- - normal official predictions remain immutable
-- - admin_recovery official predictions may be edited again only while:
--     * the member Recovery authorization is still OPEN and unexpired
--     * the target match is still currently recoverable
-- - editing converts only that recovery row back to draft
-- - a later submit_prediction_recovery_rpc re-officializes the changed row
-- - no Strategy Recovery behavior
-- =====================================================================

create or replace function public.save_prediction_recovery_draft_rpc(
    p_league_round_id uuid,
    p_match_id uuid,
    p_home_prediction integer,
    p_away_prediction integer
)
returns table(
    prediction_id uuid,
    match_id uuid,
    prediction_version integer,
    prediction_status text,
    prediction_source text,
    authorization_id uuid,
    updated_at timestamptz
)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_user_id uuid := auth.uid();

    v_league_id uuid;
    v_member_id uuid;

    v_authorization_id uuid;
    v_expires_at timestamptz;

    v_match_recoverable boolean := false;

    v_prediction public.predictions%rowtype;
    v_prediction_exists boolean := false;

    v_next_version integer;

    v_now timestamptz := clock_timestamp();
begin
    if v_user_id is null then
        raise exception using
            errcode = 'P0001',
            message = 'USER_NOT_AUTHENTICATED';
    end if;

    if p_home_prediction is null
       or p_home_prediction < 0
       or p_home_prediction > 9
       or p_away_prediction is null
       or p_away_prediction < 0
       or p_away_prediction > 9 then

        raise exception using
            errcode = 'P0001',
            message = 'PREDICTION_SCORE_INVALID';
    end if;

    select lr.league_id
    into v_league_id
    from public.league_rounds lr
    where lr.id = p_league_round_id
      and lr.enabled = true;

    if v_league_id is null then
        raise exception using
            errcode = 'P0001',
            message = 'PREDICTION_RECOVERY_ROUND_NOT_FOUND';
    end if;

    select lm.id
    into v_member_id
    from public.league_members lm
    where lm.league_id = v_league_id
      and lm.user_id = v_user_id
      and lm.status = 'active'
    limit 1;

    if v_member_id is null then
        raise exception using
            errcode = 'P0001',
            message = 'ACTIVE_LEAGUE_MEMBERSHIP_REQUIRED';
    end if;

    perform pg_advisory_xact_lock(
        hashtextextended(
            'prediction-recovery-member:' ||
            p_league_round_id::text ||
            ':' ||
            v_member_id::text,
            0
        )
    );

    select
        pra.id,
        pra.expires_at
    into
        v_authorization_id,
        v_expires_at
    from public.prediction_recovery_authorizations pra
    where pra.league_round_id = p_league_round_id
      and pra.target_member_id = v_member_id
      and pra.status = 'open'
      and pra.expires_at > v_now
    order by pra.opened_at desc
    limit 1
    for update;

    if v_authorization_id is null then
        raise exception using
            errcode = 'P0001',
            message = 'PREDICTION_RECOVERY_NOT_ACTIVE';
    end if;

    select scope.recoverable
    into v_match_recoverable
    from public.get_prediction_recovery_match_scope_internal(
        p_league_round_id,
        v_now
    ) scope
    where scope.match_id = p_match_id;

    if coalesce(v_match_recoverable, false) = false then
        raise exception using
            errcode = 'P0001',
            message = 'PREDICTION_RECOVERY_MATCH_NOT_EDITABLE';
    end if;

    select p.*
    into v_prediction
    from public.predictions p
    where p.league_round_id = p_league_round_id
      and p.league_member_id = v_member_id
      and p.match_id = p_match_id
    for update;

    v_prediction_exists := found;

    /*
     * Normal official predictions are immutable.
     *
     * Exception:
     * an official row created by admin_recovery may be reopened as draft
     * while the SAME member has an active Recovery authorization and the
     * target match remains currently recoverable.
     *
     * Authorization + recoverability were already proven above.
     */
    if v_prediction_exists
       and (
            v_prediction.submitted_version is not null
         or v_prediction.official_submitted_at is not null
         or v_prediction.status in ('submitted', 'locked')
       )
       and v_prediction.source <> 'admin_recovery' then

        raise exception using
            errcode = 'P0001',
            message = 'PREDICTION_RECOVERY_OFFICIAL_PREDICTION_IMMUTABLE';
    end if;

    if v_prediction_exists then
        v_next_version := v_prediction.version + 1;

        update public.predictions p
        set
            home_prediction = p_home_prediction,
            away_prediction = p_away_prediction,

            status = 'draft',
            source = 'admin_recovery',

            version = v_next_version,

            submitted_at = null,
            submitted_version = null,
            official_submitted_at = null,
            locked_at = null,

            updated_at = v_now
        where p.id = v_prediction.id
        returning p.*
        into v_prediction;

    else
        insert into public.predictions (
            league_id,
            user_id,
            match_id,

            home_prediction,
            away_prediction,

            league_round_id,
            league_member_id,

            status,
            source,
            version,

            created_at,
            updated_at
        )
        values (
            v_league_id,
            v_user_id,
            p_match_id,

            p_home_prediction,
            p_away_prediction,

            p_league_round_id,
            v_member_id,

            'draft',
            'admin_recovery',
            1,

            v_now,
            v_now
        )
        returning *
        into v_prediction;

        v_next_version := 1;
    end if;

    insert into public.prediction_versions (
        prediction_id,
        version,

        home_prediction,
        away_prediction,

        status,
        source,

        changed_by_user_id,
        changed_by_member_id,

        changed_at,

        metadata
    )
    values (
        v_prediction.id,
        v_prediction.version,

        v_prediction.home_prediction,
        v_prediction.away_prediction,

        'draft',
        'admin_recovery',

        v_user_id,
        v_member_id,

        v_now,

        jsonb_build_object(
            'command',
                'SavePredictionRecoveryDraft',

            'operation',
                'recovery_workspace_save',

            'recovery_authorization_id',
                v_authorization_id,

            'league_id',
                v_league_id,

            'league_round_id',
                p_league_round_id,

            'match_id',
                p_match_id,

            'expires_at',
                v_expires_at,

            'reopened_submitted_recovery',
                (
                    v_prediction_exists
                    and v_prediction.source = 'admin_recovery'
                )
        )
    );

    return query
    select
        v_prediction.id,
        v_prediction.match_id,

        v_prediction.version,
        v_prediction.status,
        v_prediction.source,

        v_authorization_id,

        v_prediction.updated_at;
end;
$function$;
