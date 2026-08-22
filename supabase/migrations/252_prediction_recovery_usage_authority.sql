-- ============================================================================
-- FANTAGOL
-- MIGRATION 252
-- PREDICTION RECOVERY USAGE AUTHORITY
--
-- R40-R13C3
--
-- Dependencies:
--   250_prediction_recovery_opening_authority.sql
--   251_strategy_recovery_authority.sql
--
-- Contract:
--
-- * only a member holding an OPEN Prediction Recovery authorization may use
--   these RPCs;
--
-- * Recovery never restores already-started matches;
--
-- * match eligibility is re-evaluated server-side at every command;
--
-- * saving one match is allowed while building the Recovery workspace;
--
-- * submission is atomic over ALL matches still recoverable at submit time;
--
-- * if a match starts after Recovery opening but before submission:
--       - it leaves the editable scope;
--       - an admin_recovery draft for it is voided;
--       - it remains non-official and therefore missing = 0;
--
-- * submitted Recovery predictions become immediately official because the
--   normal global Prediction lock already occurred;
--
-- * normal save_prediction_draft_rpc / submit_round_predictions_rpc remain
--   untouched.
-- ============================================================================

begin;


-- ============================================================================
-- A. MEMBER RECOVERY WORKSPACE
-- ============================================================================

create or replace function public.get_my_prediction_recovery_workspace_rpc(
    p_league_round_id uuid
)
returns table (
    league_round_id uuid,
    league_member_id uuid,

    authorization_id uuid,
    authorization_expires_at timestamptz,

    match_id uuid,
    kickoff timestamptz,
    match_status text,

    editable boolean,

    prediction_id uuid,
    home_prediction integer,
    away_prediction integer,

    prediction_status text,
    prediction_source text,
    prediction_version integer,
    submitted_version integer,
    official_submitted_at timestamptz
)
language plpgsql
stable
security definer
set search_path to public, pg_temp
as $function$
declare
    v_user_id uuid := auth.uid();

    v_league_id uuid;
    v_member_id uuid;

    v_authorization_id uuid;
    v_expires_at timestamptz;

    v_now timestamptz := clock_timestamp();
begin

    if v_user_id is null then
        raise exception using
            errcode = 'P0001',
            message = 'USER_NOT_AUTHENTICATED';
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
    limit 1;


    if v_authorization_id is null then
        raise exception using
            errcode = 'P0001',
            message = 'PREDICTION_RECOVERY_NOT_ACTIVE';
    end if;


    return query

    select
        p_league_round_id,
        v_member_id,

        v_authorization_id,
        v_expires_at,

        scope.match_id,
        scope.kickoff,
        m.status,

        scope.recoverable
          and scope.kickoff > v_now
          and v_expires_at > v_now,

        p.id,

        /*
         * Existing unfinished pre-lock workspace values may be shown to the
         * same member as a convenience. They are NOT official until Recovery
         * submission succeeds.
         */
        p.home_prediction,
        p.away_prediction,

        p.status,
        p.source,
        p.version,
        p.submitted_version,
        p.official_submitted_at

    from public.get_prediction_recovery_match_scope_internal(
        p_league_round_id,
        v_now
    ) scope

    join public.matches m
      on m.id = scope.match_id

    left join public.predictions p
      on p.league_round_id = p_league_round_id
     and p.league_member_id = v_member_id
     and p.match_id = scope.match_id

    order by
        scope.kickoff,
        scope.match_id;

end;
$function$;


comment on function
public.get_my_prediction_recovery_workspace_rpc(uuid)
is
'Authenticated Prediction Recovery workspace. Returns every required match while server-side editable marks only matches still recoverable at request time.';


-- ============================================================================
-- B. SAVE ONE RECOVERY PREDICTION
-- ============================================================================

create or replace function public.save_prediction_recovery_draft_rpc(
    p_league_round_id uuid,
    p_match_id uuid,
    p_home_prediction integer,
    p_away_prediction integer
)
returns table (
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
set search_path to public, pg_temp
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


    /*
     * All member Recovery mutations share one transaction authority.
     * R40-R13C4 close/relock will use the same key.
     */
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
     * Recovery can never overwrite an already-official prediction.
     */
    if v_prediction_exists
       and (
            v_prediction.submitted_version is not null
         or v_prediction.official_submitted_at is not null
         or v_prediction.status in ('submitted', 'locked')
       ) then

        raise exception using
            errcode = 'P0001',
            message = 'PREDICTION_RECOVERY_OFFICIAL_PREDICTION_IMMUTABLE';
    end if;


    if v_prediction_exists then

        v_next_version :=
            v_prediction.version + 1;


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
                v_expires_at
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


comment on function
public.save_prediction_recovery_draft_rpc(uuid,uuid,integer,integer)
is
'Authenticated Prediction Recovery save command. Only currently-recoverable matches may be written; official predictions are immutable.';


-- ============================================================================
-- C. SUBMIT COMPLETE CURRENT RECOVERY RESIDUAL
-- ============================================================================

create or replace function public.submit_prediction_recovery_rpc(
    p_league_round_id uuid
)
returns table (
    league_round_id uuid,
    league_member_id uuid,
    authorization_id uuid,

    current_recoverable_match_count integer,
    submitted_prediction_count integer,
    newly_submitted_prediction_count integer,

    voided_started_recovery_draft_count integer,

    already_submitted boolean,
    submitted_at timestamptz
)
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
    v_user_id uuid := auth.uid();

    v_league_id uuid;
    v_member_id uuid;

    v_authorization_id uuid;
    v_expires_at timestamptz;

    v_required_count integer := 0;
    v_present_count integer := 0;

    v_existing_official_count integer := 0;
    v_conflicting_official_count integer := 0;

    v_newly_submitted integer := 0;
    v_voided_started integer := 0;

    v_submitted_count integer := 0;
    v_submitted_at timestamptz;

    v_now timestamptz := clock_timestamp();
begin

    if v_user_id is null then
        raise exception using
            errcode = 'P0001',
            message = 'USER_NOT_AUTHENTICATED';
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


    /*
     * Current residual authority is dynamic.
     * Matches that started since Recovery opening are no longer part of the
     * required Recovery submission.
     */
    select count(*)::integer
    into v_required_count
    from public.get_prediction_recovery_match_scope_internal(
        p_league_round_id,
        v_now
    ) scope
    where scope.recoverable;


    if v_required_count <= 0 then
        raise exception using
            errcode = 'P0001',
            message = 'PREDICTION_RECOVERY_NO_ELIGIBLE_MATCHES';
    end if;


    /*
     * Every currently-recoverable match must already have a Prediction row.
     * This is the Recovery equivalent of ROUND_PREDICTIONS_INCOMPLETE.
     */
    select count(*)::integer
    into v_present_count

    from public.get_prediction_recovery_match_scope_internal(
        p_league_round_id,
        v_now
    ) scope

    join public.predictions p
      on p.league_round_id = p_league_round_id
     and p.league_member_id = v_member_id
     and p.match_id = scope.match_id

    where scope.recoverable;


    if v_present_count <> v_required_count then
        raise exception using
            errcode = 'P0001',
            message = 'PREDICTION_RECOVERY_INCOMPLETE',
            detail = format(
                'required=%s present=%s missing=%s',
                v_required_count,
                v_present_count,
                greatest(
                    v_required_count - v_present_count,
                    0
                )
            );
    end if;


    /*
     * A Recovery target should not contain pre-existing official predictions
     * in the current residual. If such a state ever appears, fail closed.
     *
     * admin_recovery official rows are allowed for idempotent retries.
     */
    select
        count(*) filter (
            where p.submitted_version is not null
              and p.source = 'admin_recovery'
        )::integer,

        count(*) filter (
            where p.submitted_version is not null
              and p.source <> 'admin_recovery'
        )::integer

    into
        v_existing_official_count,
        v_conflicting_official_count

    from public.get_prediction_recovery_match_scope_internal(
        p_league_round_id,
        v_now
    ) scope

    join public.predictions p
      on p.league_round_id = p_league_round_id
     and p.league_member_id = v_member_id
     and p.match_id = scope.match_id

    where scope.recoverable;


    if v_conflicting_official_count > 0 then
        raise exception using
            errcode = 'P0001',
            message = 'PREDICTION_RECOVERY_OFFICIAL_SCOPE_CONFLICT';
    end if;


    /*
     * Fully idempotent retry.
     */
    if v_existing_official_count = v_required_count then

        select min(p.official_submitted_at)
        into v_submitted_at

        from public.get_prediction_recovery_match_scope_internal(
            p_league_round_id,
            v_now
        ) scope

        join public.predictions p
          on p.league_round_id = p_league_round_id
         and p.league_member_id = v_member_id
         and p.match_id = scope.match_id

        where scope.recoverable
          and p.submitted_version is not null
          and p.source = 'admin_recovery';


        return query
        select
            p_league_round_id,
            v_member_id,
            v_authorization_id,

            v_required_count,
            v_required_count,
            0,

            0,

            true,
            v_submitted_at;

        return;
    end if;


    /*
     * Any Recovery draft whose match has meanwhile started is permanently
     * excluded. It must never become official later.
     */
    with to_void as (

        select p.id
        from public.predictions p

        join public.league_rounds lr
          on lr.id = p.league_round_id

        join public.fantagol_round_matches frm
          on frm.fantagol_round_id =
             lr.fantagol_round_id
         and frm.match_id = p.match_id
         and frm.required
         and frm.removed_at is null

        join public.matches m
          on m.id = p.match_id

        where p.league_round_id = p_league_round_id
          and p.league_member_id = v_member_id

          and p.source = 'admin_recovery'
          and p.status = 'draft'
          and p.submitted_version is null

          and m.kickoff <= v_now
    ),

    changed as (

        update public.predictions p
        set
            status = 'void',
            version = p.version + 1,
            updated_at = v_now
        where p.id in (
            select tv.id
            from to_void tv
        )
        returning p.*
    ),

    history as (

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

        select
            c.id,
            c.version,

            c.home_prediction,
            c.away_prediction,

            'void',
            'admin_recovery',

            v_user_id,
            v_member_id,

            v_now,

            jsonb_build_object(
                'command',
                    'SubmitPredictionRecovery',

                'operation',
                    'recovery_started_match_void',

                'recovery_authorization_id',
                    v_authorization_id,

                'league_round_id',
                    p_league_round_id,

                'match_id',
                    c.match_id,

                'reason',
                    'match_started_before_recovery_submit'
            )

        from changed c

        returning prediction_id
    )

    select count(*)::integer
    into v_voided_started
    from history;


    /*
     * Promote every non-official current residual row atomically.
     *
     * submitted_version points to the immutable submitted snapshot created
     * by this very transition.
     */
    with eligible as (

        select p.id
        from public.get_prediction_recovery_match_scope_internal(
            p_league_round_id,
            v_now
        ) scope

        join public.predictions p
          on p.league_round_id = p_league_round_id
         and p.league_member_id = v_member_id
         and p.match_id = scope.match_id

        where scope.recoverable
          and p.submitted_version is null
    ),

    changed as (

        update public.predictions p
        set
            status = 'submitted',
            source = 'admin_recovery',

            version = p.version + 1,

            submitted_at =
                coalesce(
                    p.submitted_at,
                    v_now
                ),

            submitted_version =
                p.version + 1,

            official_submitted_at =
                coalesce(
                    p.official_submitted_at,
                    v_now
                ),

            locked_at = null,

            updated_at = v_now

        where p.id in (
            select e.id
            from eligible e
        )

        returning p.*
    ),

    history as (

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

        select
            c.id,
            c.version,

            c.home_prediction,
            c.away_prediction,

            'submitted',
            'admin_recovery',

            v_user_id,
            v_member_id,

            v_now,

            jsonb_build_object(
                'command',
                    'SubmitPredictionRecovery',

                'operation',
                    'recovery_submit',

                'recovery_authorization_id',
                    v_authorization_id,

                'league_id',
                    v_league_id,

                'league_round_id',
                    p_league_round_id,

                'match_id',
                    c.match_id,

                'submitted_version',
                    c.submitted_version
            )

        from changed c

        returning prediction_id
    )

    select count(*)::integer
    into v_newly_submitted
    from history;


    /*
     * Hard official postcondition over the CURRENT residual.
     */
    select
        count(*)::integer,
        min(p.official_submitted_at)

    into
        v_submitted_count,
        v_submitted_at

    from public.get_prediction_recovery_match_scope_internal(
        p_league_round_id,
        v_now
    ) scope

    join public.predictions p
      on p.league_round_id = p_league_round_id
     and p.league_member_id = v_member_id
     and p.match_id = scope.match_id

    where scope.recoverable

      and p.status in (
          'submitted',
          'locked'
      )

      and p.source = 'admin_recovery'

      and p.submitted_version is not null
      and p.official_submitted_at is not null;


    if v_submitted_count <> v_required_count then
        raise exception using
            errcode = 'P0001',
            message = 'PREDICTION_RECOVERY_SUBMISSION_INVARIANT_FAILED',
            detail = format(
                'required=%s official=%s',
                v_required_count,
                v_submitted_count
            );
    end if;


    return query
    select
        p_league_round_id,
        v_member_id,
        v_authorization_id,

        v_required_count,
        v_submitted_count,
        v_newly_submitted,

        v_voided_started,

        false,
        v_submitted_at;

end;
$function$;


comment on function
public.submit_prediction_recovery_rpc(uuid)
is
'Authenticated atomic Recovery submission over the entire set of matches still recoverable at command time. Newly-started Recovery drafts are voided and remain missing.';


-- ============================================================================
-- D. SECURITY
-- ============================================================================

revoke all
on function public.get_my_prediction_recovery_workspace_rpc(uuid)
from public, anon;

grant execute
on function public.get_my_prediction_recovery_workspace_rpc(uuid)
to authenticated, service_role;


revoke all
on function public.save_prediction_recovery_draft_rpc(
    uuid,
    uuid,
    integer,
    integer
)
from public, anon;

grant execute
on function public.save_prediction_recovery_draft_rpc(
    uuid,
    uuid,
    integer,
    integer
)
to authenticated, service_role;


revoke all
on function public.submit_prediction_recovery_rpc(uuid)
from public, anon;

grant execute
on function public.submit_prediction_recovery_rpc(uuid)
to authenticated, service_role;


-- ============================================================================
-- E. INSTALLATION CONTRACT
-- ============================================================================

do $verification$
declare
    v_workspace text;
    v_save text;
    v_submit text;
begin

    select pg_get_functiondef(
        'public.get_my_prediction_recovery_workspace_rpc(uuid)'::regprocedure
    )
    into v_workspace;


    select pg_get_functiondef(
        'public.save_prediction_recovery_draft_rpc(uuid,uuid,integer,integer)'::regprocedure
    )
    into v_save;


    select pg_get_functiondef(
        'public.submit_prediction_recovery_rpc(uuid)'::regprocedure
    )
    into v_submit;


    if v_workspace is null
       or v_save is null
       or v_submit is null then

        raise exception
            'PREDICTION_RECOVERY_USAGE_COMPONENT_MISSING';
    end if;


    if position(
        'get_prediction_recovery_match_scope_internal'
        in v_workspace
    ) = 0
       or position(
        'get_prediction_recovery_match_scope_internal'
        in v_save
    ) = 0
       or position(
        'get_prediction_recovery_match_scope_internal'
        in v_submit
    ) = 0 then

        raise exception
            'PREDICTION_RECOVERY_DYNAMIC_SCOPE_MISSING';
    end if;


    if position(
        'prediction-recovery-member:'
        in v_save
    ) = 0
       or position(
        'prediction-recovery-member:'
        in v_submit
    ) = 0 then

        raise exception
            'PREDICTION_RECOVERY_COMMON_MEMBER_LOCK_MISSING';
    end if;


    if position(
        'PREDICTION_RECOVERY_MATCH_NOT_EDITABLE'
        in v_save
    ) = 0 then

        raise exception
            'PREDICTION_RECOVERY_KICKOFF_SAVE_GATE_MISSING';
    end if;


    if position(
        'PREDICTION_RECOVERY_INCOMPLETE'
        in v_submit
    ) = 0 then

        raise exception
            'PREDICTION_RECOVERY_ATOMIC_SUBMISSION_GATE_MISSING';
    end if;


    if position(
        'recovery_started_match_void'
        in v_submit
    ) = 0 then

        raise exception
            'PREDICTION_RECOVERY_STARTED_DRAFT_VOID_MISSING';
    end if;


    if position(
        'official_submitted_at'
        in v_submit
    ) = 0
       or position(
        'submitted_version'
        in v_submit
    ) = 0 then

        raise exception
            'PREDICTION_RECOVERY_OFFICIAL_SNAPSHOT_MISSING';
    end if;

end;
$verification$;


commit;