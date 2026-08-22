-- ============================================================================
-- FANTAGOL
-- MIGRATION 253
-- PREDICTION RECOVERY CLOSE / RELOCK AUTHORITY
--
-- R40-R13C4
--
-- Dependencies:
--   250 Prediction Recovery Opening Authority
--   251 Strategy Recovery Authority
--   252 Prediction Recovery Usage Authority
--
-- Contract:
--
-- EARLY CLOSE
--   * allowed only when every currently recoverable Prediction is already
--     official admin_recovery;
--
-- EXPIRY CLOSE
--   * allowed when authorization.expires_at <= close time;
--   * unsubmitted Prediction Recovery drafts are voided;
--   * absent Prediction rows remain missing = 0.
--
-- STRATEGY CLOSE
--   * submitted Strategy -> lock exact official submitted snapshot;
--   * draft/default Strategy -> validate complete payload, auto-submit it,
--     then lock that exact payload;
--   * Strategy can therefore never remain missing after Recovery relock.
--
-- TERMINAL AUTHORIZATION
--   * early completed close -> used;
--   * time-expired close    -> expired.
--
-- ROUND
--   * no global round status mutation;
--   * no league-round status mutation.
--
-- CONCURRENCY
--   * Prediction uses the common member authority introduced by 252;
--   * close also acquires all Strategy save/submit authorities;
--   * a trigger rejects delayed admin_recovery Strategy writes after the
--     authorization becomes terminal.
-- ============================================================================

begin;


-- ============================================================================
-- A. TERMINAL STRATEGY WRITE GUARD
-- ============================================================================

create or replace function
public.guard_strategy_recovery_version_write_internal()
returns trigger
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
    v_authorization_id uuid;
    v_authorization_status text;
    v_expires_at timestamptz;
    v_operation text;

    v_now timestamptz := clock_timestamp();
begin

    if new.source <> 'admin_recovery' then
        return new;
    end if;


    v_operation :=
        new.metadata ->> 'operation';


    begin
        v_authorization_id :=
            nullif(
                new.metadata ->> 'recovery_authorization_id',
                ''
            )::uuid;
    exception
        when invalid_text_representation then
            raise exception using
                errcode = 'P0001',
                message = 'STRATEGY_RECOVERY_AUTHORIZATION_METADATA_INVALID';
    end;


    if v_authorization_id is null then
        raise exception using
            errcode = 'P0001',
            message = 'STRATEGY_RECOVERY_AUTHORIZATION_METADATA_REQUIRED';
    end if;


    select
        pra.status,
        pra.expires_at
    into
        v_authorization_status,
        v_expires_at
    from public.prediction_recovery_authorizations pra
    where pra.id = v_authorization_id;


    if v_authorization_status is null then
        raise exception using
            errcode = 'P0001',
            message = 'STRATEGY_RECOVERY_AUTHORIZATION_NOT_FOUND';
    end if;


    /*
     * Close itself is allowed to materialize terminal submitted/locked
     * snapshots after the nominal expiry instant, provided authorization
     * status is still OPEN inside the closing transaction.
     */
    if v_operation in (
        'recovery_close_auto_submit',
        'recovery_close_lock_auto_submitted',
        'recovery_close_lock_official'
    ) then

        if v_authorization_status <> 'open' then
            raise exception using
                errcode = 'P0001',
                message = 'STRATEGY_RECOVERY_ALREADY_TERMINAL';
        end if;

        return new;
    end if;


    /*
     * Normal Recovery writes require both OPEN status and unexpired time.
     */
    if v_authorization_status <> 'open'
       or v_expires_at <= v_now then

        raise exception using
            errcode = 'P0001',
            message = 'STRATEGY_RECOVERY_WRITE_WINDOW_CLOSED';
    end if;


    return new;

end;
$function$;


drop trigger if exists
guard_strategy_recovery_version_write_trg
on public.strategy_versions;


create trigger
guard_strategy_recovery_version_write_trg
before insert or update
on public.strategy_versions
for each row
execute function
public.guard_strategy_recovery_version_write_internal();


-- ============================================================================
-- B. CORE CLOSE / RELOCK AUTHORITY
-- ============================================================================

create or replace function
public.finalize_prediction_recovery_authorization_internal(
    p_authorization_id uuid,
    p_at timestamptz default clock_timestamp(),
    p_reason text default null
)
returns table (
    authorization_id uuid,
    league_round_id uuid,
    league_member_id uuid,

    terminal_status text,

    current_recoverable_match_count integer,
    current_official_recovery_prediction_count integer,
    voided_recovery_prediction_count integer,

    strategy_mode_count integer,
    strategy_locked_count integer,
    strategy_auto_submitted_count integer,
    strategy_official_locked_count integer,

    already_terminal boolean,
    finalized_at timestamptz
)
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
    v_authorization public.prediction_recovery_authorizations%rowtype;

    v_current_recoverable integer := 0;
    v_current_official integer := 0;

    v_voided_predictions integer := 0;

    v_mode text;
    v_fixture_id uuid;

    v_strategy public.strategies%rowtype;

    v_payload jsonb;
    v_submitted_payload jsonb;

    v_submission_version integer;
    v_locked_version integer;

    v_strategy_modes integer := 0;
    v_strategy_locked integer := 0;
    v_strategy_auto_submitted integer := 0;
    v_strategy_official_locked integer := 0;

    v_terminal_status text;
begin

    if p_authorization_id is null then
        raise exception using
            errcode = 'P0001',
            message = 'PREDICTION_RECOVERY_AUTHORIZATION_REQUIRED';
    end if;


    select pra.*
    into v_authorization
    from public.prediction_recovery_authorizations pra
    where pra.id = p_authorization_id
    for update;


    if not found then
        raise exception using
            errcode = 'P0001',
            message = 'PREDICTION_RECOVERY_AUTHORIZATION_NOT_FOUND';
    end if;


    if v_authorization.status in (
        'used',
        'expired',
        'revoked'
    ) then

        return query
        select
            v_authorization.id,
            v_authorization.league_round_id,
            v_authorization.target_member_id,

            v_authorization.status,

            0,
            0,
            0,

            0,
            0,
            0,
            0,

            true,
            p_at;

        return;
    end if;


    if v_authorization.status <> 'open' then
        raise exception using
            errcode = 'P0001',
            message = 'PREDICTION_RECOVERY_AUTHORIZATION_STATE_INVALID';
    end if;


    /*
     * Serialize every Prediction Recovery mutation for this member.
     */
    perform pg_advisory_xact_lock(
        hashtextextended(
            'prediction-recovery-member:' ||
            v_authorization.league_round_id::text ||
            ':' ||
            v_authorization.target_member_id::text,
            0
        )
    );


    /*
     * Serialize against the current 251 Strategy save and submit commands.
     *
     * Fixed acquisition order:
     *   fantacalcio save
     *   fantacalcio submit
     *   one_to_one save
     *   one_to_one submit
     */
    perform pg_advisory_xact_lock(
        hashtextextended(
            'strategy-recovery-save:' ||
            v_authorization.league_round_id::text ||
            ':' ||
            v_authorization.target_member_id::text ||
            ':fantacalcio',
            0
        )
    );

    perform pg_advisory_xact_lock(
        hashtextextended(
            'strategy-recovery-submit:' ||
            v_authorization.league_round_id::text ||
            ':' ||
            v_authorization.target_member_id::text ||
            ':fantacalcio',
            0
        )
    );

    perform pg_advisory_xact_lock(
        hashtextextended(
            'strategy-recovery-save:' ||
            v_authorization.league_round_id::text ||
            ':' ||
            v_authorization.target_member_id::text ||
            ':one_to_one',
            0
        )
    );

    perform pg_advisory_xact_lock(
        hashtextextended(
            'strategy-recovery-submit:' ||
            v_authorization.league_round_id::text ||
            ':' ||
            v_authorization.target_member_id::text ||
            ':one_to_one',
            0
        )
    );


    /*
     * Current Prediction residual.
     */
    select count(*)::integer
    into v_current_recoverable
    from public.get_prediction_recovery_match_scope_internal(
        v_authorization.league_round_id,
        p_at
    ) scope
    where scope.recoverable;


    select count(*)::integer
    into v_current_official

    from public.get_prediction_recovery_match_scope_internal(
        v_authorization.league_round_id,
        p_at
    ) scope

    join public.predictions p
      on p.league_round_id =
         v_authorization.league_round_id
     and p.league_member_id =
         v_authorization.target_member_id
     and p.match_id =
         scope.match_id

    where scope.recoverable

      and p.source = 'admin_recovery'

      and p.status in (
          'submitted',
          'locked'
      )

      and p.submitted_version is not null
      and p.official_submitted_at is not null;


    /*
     * Before expiry, close is allowed only after complete residual delivery.
     */
    if p_at < v_authorization.expires_at
       and v_current_official <> v_current_recoverable then

        raise exception using
            errcode = 'P0001',
            message = 'PREDICTION_RECOVERY_NOT_COMPLETE',
            detail = format(
                'recoverable=%s official=%s missing=%s',
                v_current_recoverable,
                v_current_official,
                greatest(
                    v_current_recoverable -
                    v_current_official,
                    0
                )
            );
    end if;


    /*
     * Anything still draft when Recovery closes can never become official.
     *
     * At expiry this also covers matches whose kickoff may have been moved
     * after Recovery opening: the authorization itself is over.
     */
    with changed as (

        update public.predictions p
        set
            status = 'void',
            version = p.version + 1,
            updated_at = p_at

        where p.league_round_id =
              v_authorization.league_round_id

          and p.league_member_id =
              v_authorization.target_member_id

          and p.source = 'admin_recovery'
          and p.status = 'draft'
          and p.submitted_version is null

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

            null,
            null,

            p_at,

            jsonb_build_object(
                'command',
                    'FinalizePredictionRecovery',

                'operation',
                    'recovery_close_void_unsubmitted',

                'recovery_authorization_id',
                    v_authorization.id,

                'league_round_id',
                    v_authorization.league_round_id,

                'match_id',
                    c.match_id,

                'reason',
                    coalesce(
                        nullif(btrim(p_reason), ''),
                        'recovery_closed'
                    )
            )

        from changed c

        returning prediction_id
    )

    select count(*)::integer
    into v_voided_predictions
    from history;


    /*
     * Finalize both Strategy modes.
     *
     * The Strategy aggregate is guaranteed by 251 Recovery materialization.
     */
    foreach v_mode in array array[
        'fantacalcio'::text,
        'one_to_one'::text
    ]
    loop

        v_fixture_id := null;
        v_strategy := null;
        v_payload := null;
        v_submitted_payload := null;


        select lf.id
        into v_fixture_id
        from public.league_fixtures lf
        join public.league_schedule_versions lsv
          on lsv.id = lf.schedule_version_id
         and lsv.active = true
        where lf.league_round_id =
              v_authorization.league_round_id
          and lf.mode = v_mode
          and lf.is_bye = false
          and (
               lf.home_member_id =
                   v_authorization.target_member_id
            or lf.away_member_id =
                   v_authorization.target_member_id
          )
        limit 1;


        if v_fixture_id is null then
            continue;
        end if;


        v_strategy_modes :=
            v_strategy_modes + 1;


        select s.*
        into v_strategy
        from public.strategies s
        where s.league_fixture_id =
              v_fixture_id
          and s.league_member_id =
              v_authorization.target_member_id
        for update;


        if not found then
            raise exception using
                errcode = 'P0001',
                message = 'STRATEGY_RECOVERY_WORKSPACE_NOT_FOUND',
                detail = format(
                    'mode=%s authorization_id=%s',
                    v_mode,
                    v_authorization.id
                );
        end if;


        /*
         * Idempotent mode-level terminal state.
         */
        if v_strategy.status = 'locked'
           and v_strategy.source = 'admin_recovery' then

            v_strategy_locked :=
                v_strategy_locked + 1;

            continue;
        end if;


        -- --------------------------------------------------------
        -- A. Explicit Recovery submitted snapshot exists
        -- --------------------------------------------------------

        if v_strategy.submitted_version is not null then

            select sv.payload
            into v_submitted_payload
            from public.strategy_versions sv
            where sv.strategy_id =
                  v_strategy.id
              and sv.version =
                  v_strategy.submitted_version;


            if v_submitted_payload is null then
                raise exception using
                    errcode = 'P0001',
                    message = 'STRATEGY_RECOVERY_OFFICIAL_VERSION_NOT_FOUND',
                    detail = format(
                        'mode=%s strategy_id=%s submitted_version=%s',
                        v_mode,
                        v_strategy.id,
                        v_strategy.submitted_version
                    );
            end if;


            perform public.validate_strategy_submission_payload(
                v_mode,
                v_submitted_payload,
                v_authorization.league_round_id
            );


            v_locked_version :=
                v_strategy.version + 1;


            insert into public.strategy_versions (
                strategy_id,
                version,
                payload,
                status,
                source,
                changed_by_user_id,
                changed_by_member_id,
                changed_at,
                metadata
            )
            values (
                v_strategy.id,
                v_locked_version,
                v_submitted_payload,
                'locked',
                'admin_recovery',
                null,
                null,
                p_at,
                jsonb_build_object(
                    'operation',
                        'recovery_close_lock_official',

                    'recovery_authorization_id',
                        v_authorization.id,

                    'mode',
                        v_mode,

                    'league_round_id',
                        v_authorization.league_round_id,

                    'league_fixture_id',
                        v_fixture_id,

                    'official_submitted_version',
                        v_strategy.submitted_version,

                    'reason',
                        coalesce(
                            nullif(btrim(p_reason), ''),
                            'recovery_closed'
                        )
                )
            );


            update public.strategies s
            set
                status = 'locked',
                source = 'admin_recovery',
                version = v_locked_version,
                locked_at = p_at,
                updated_at = p_at
            where s.id = v_strategy.id;


            v_strategy_locked :=
                v_strategy_locked + 1;

            v_strategy_official_locked :=
                v_strategy_official_locked + 1;

            continue;
        end if;


        -- --------------------------------------------------------
        -- B. No explicit submitted Strategy:
        --    current complete workspace/default becomes official.
        -- --------------------------------------------------------

        select sv.payload
        into v_payload
        from public.strategy_versions sv
        where sv.strategy_id =
              v_strategy.id
          and sv.version =
              v_strategy.version;


        if v_payload is null then
            raise exception using
                errcode = 'P0001',
                message = 'STRATEGY_RECOVERY_WORKSPACE_VERSION_NOT_FOUND',
                detail = format(
                    'mode=%s strategy_id=%s version=%s',
                    v_mode,
                    v_strategy.id,
                    v_strategy.version
                );
        end if;


        perform public.validate_strategy_submission_payload(
            v_mode,
            v_payload,
            v_authorization.league_round_id
        );


        v_submission_version :=
            v_strategy.version + 1;

        v_locked_version :=
            v_strategy.version + 2;


        insert into public.strategy_versions (
            strategy_id,
            version,
            payload,
            status,
            source,
            changed_by_user_id,
            changed_by_member_id,
            changed_at,
            metadata
        )
        values (
            v_strategy.id,
            v_submission_version,
            v_payload,
            'submitted',
            'admin_recovery',
            null,
            null,
            p_at,
            jsonb_build_object(
                'operation',
                    'recovery_close_auto_submit',

                'recovery_authorization_id',
                    v_authorization.id,

                'mode',
                    v_mode,

                'league_round_id',
                    v_authorization.league_round_id,

                'league_fixture_id',
                    v_fixture_id,

                'workspace_source_version',
                    v_strategy.version,

                'official_submitted_version',
                    v_submission_version,

                'reason',
                    coalesce(
                        nullif(btrim(p_reason), ''),
                        'recovery_closed'
                    )
            )
        );


        insert into public.strategy_versions (
            strategy_id,
            version,
            payload,
            status,
            source,
            changed_by_user_id,
            changed_by_member_id,
            changed_at,
            metadata
        )
        values (
            v_strategy.id,
            v_locked_version,
            v_payload,
            'locked',
            'admin_recovery',
            null,
            null,
            p_at,
            jsonb_build_object(
                'operation',
                    'recovery_close_lock_auto_submitted',

                'recovery_authorization_id',
                    v_authorization.id,

                'mode',
                    v_mode,

                'league_round_id',
                    v_authorization.league_round_id,

                'league_fixture_id',
                    v_fixture_id,

                'official_submitted_version',
                    v_submission_version,

                'reason',
                    coalesce(
                        nullif(btrim(p_reason), ''),
                        'recovery_closed'
                    )
            )
        );


        update public.strategies s
        set
            status = 'locked',
            source = 'admin_recovery',

            version = v_locked_version,

            submitted_version =
                v_submission_version,

            submitted_at =
                coalesce(
                    s.submitted_at,
                    p_at
                ),

            official_submitted_at =
                coalesce(
                    s.official_submitted_at,
                    p_at
                ),

            locked_at = p_at,
            updated_at = p_at

        where s.id =
              v_strategy.id;


        v_strategy_locked :=
            v_strategy_locked + 1;

        v_strategy_auto_submitted :=
            v_strategy_auto_submitted + 1;

    end loop;


    if v_strategy_modes <> v_strategy_locked then
        raise exception using
            errcode = 'P0001',
            message = 'STRATEGY_RECOVERY_RELOCK_INCOMPLETE',
            detail = format(
                'modes=%s locked=%s',
                v_strategy_modes,
                v_strategy_locked
            );
    end if;


    /*
     * Terminal authorization status.
     */
    v_terminal_status :=
        case
            when p_at >= v_authorization.expires_at
            then 'expired'
            else 'used'
        end;


    update public.prediction_recovery_authorizations pra
    set
        status = v_terminal_status,
        updated_at = p_at,
        version = pra.version + 1
    where pra.id =
          v_authorization.id;


    return query
    select
        v_authorization.id,
        v_authorization.league_round_id,
        v_authorization.target_member_id,

        v_terminal_status,

        v_current_recoverable,
        v_current_official,
        v_voided_predictions,

        v_strategy_modes,
        v_strategy_locked,
        v_strategy_auto_submitted,
        v_strategy_official_locked,

        false,
        p_at;

end;
$function$;


comment on function
public.finalize_prediction_recovery_authorization_internal(
    uuid,
    timestamptz,
    text
)
is
'Canonical Prediction Recovery terminalizer. Early close requires complete current residual; expiry close voids unfinished Prediction drafts and always finalizes Strategy Recovery into official locked state.';


-- ============================================================================
-- C. MEMBER EARLY-CLOSE RPC
-- ============================================================================

create or replace function
public.close_my_prediction_recovery_rpc(
    p_league_round_id uuid
)
returns table (
    authorization_id uuid,
    league_round_id uuid,
    league_member_id uuid,

    terminal_status text,

    current_recoverable_match_count integer,
    current_official_recovery_prediction_count integer,
    voided_recovery_prediction_count integer,

    strategy_mode_count integer,
    strategy_locked_count integer,
    strategy_auto_submitted_count integer,
    strategy_official_locked_count integer,

    already_terminal boolean,
    finalized_at timestamptz
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
    where lr.id =
          p_league_round_id
      and lr.enabled = true;


    if v_league_id is null then
        raise exception using
            errcode = 'P0001',
            message = 'PREDICTION_RECOVERY_ROUND_NOT_FOUND';
    end if;


    select lm.id
    into v_member_id
    from public.league_members lm
    where lm.league_id =
          v_league_id
      and lm.user_id =
          v_user_id
      and lm.status = 'active'
    limit 1;


    if v_member_id is null then
        raise exception using
            errcode = 'P0001',
            message = 'ACTIVE_LEAGUE_MEMBERSHIP_REQUIRED';
    end if;


    select pra.id
    into v_authorization_id
    from public.prediction_recovery_authorizations pra
    where pra.league_round_id =
          p_league_round_id
      and pra.target_member_id =
          v_member_id
      and pra.status = 'open'
    order by pra.opened_at desc
    limit 1;


    if v_authorization_id is null then
        raise exception using
            errcode = 'P0001',
            message = 'PREDICTION_RECOVERY_NOT_ACTIVE';
    end if;


    return query
    select *
    from public.finalize_prediction_recovery_authorization_internal(
        v_authorization_id,
        v_now,
        'member_completed_recovery'
    );

end;
$function$;


comment on function
public.close_my_prediction_recovery_rpc(uuid)
is
'Authenticated early Recovery close. Current Prediction residual must already be completely official; Strategy draft/default is auto-submitted and locked.';


-- ============================================================================
-- D. EXPIRED AUTHORIZATION SWEEP
-- ============================================================================

create or replace function
public.expire_due_prediction_recoveries_internal(
    p_at timestamptz default clock_timestamp()
)
returns table (
    processed_authorization_count integer,
    expired_authorization_count integer,

    strategy_locked_count integer,
    strategy_auto_submitted_count integer,

    voided_recovery_prediction_count integer,

    processed_at timestamptz
)
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
    v_item record;
    v_result record;

    v_processed integer := 0;
    v_expired integer := 0;

    v_strategy_locked integer := 0;
    v_strategy_auto_submitted integer := 0;

    v_voided_predictions integer := 0;
begin

    for v_item in

        select pra.id
        from public.prediction_recovery_authorizations pra
        where pra.status = 'open'
          and pra.expires_at <= p_at
        order by
            pra.expires_at,
            pra.id

    loop

        select *
        into v_result
        from public.finalize_prediction_recovery_authorization_internal(
            v_item.id,
            p_at,
            'recovery_window_expired'
        );


        v_processed :=
            v_processed + 1;


        if v_result.terminal_status = 'expired' then
            v_expired :=
                v_expired + 1;
        end if;


        v_strategy_locked :=
            v_strategy_locked +
            coalesce(
                v_result.strategy_locked_count,
                0
            );


        v_strategy_auto_submitted :=
            v_strategy_auto_submitted +
            coalesce(
                v_result.strategy_auto_submitted_count,
                0
            );


        v_voided_predictions :=
            v_voided_predictions +
            coalesce(
                v_result.voided_recovery_prediction_count,
                0
            );

    end loop;


    return query
    select
        v_processed,
        v_expired,

        v_strategy_locked,
        v_strategy_auto_submitted,

        v_voided_predictions,

        p_at;

end;
$function$;


comment on function
public.expire_due_prediction_recoveries_internal(timestamptz)
is
'Service-role sweep for OPEN Prediction Recovery authorizations whose expiry has been reached. Finalizes Strategy and voids unfinished Recovery Prediction drafts.';


-- ============================================================================
-- E. SECURITY
-- ============================================================================

revoke all
on function public.guard_strategy_recovery_version_write_internal()
from public, anon, authenticated;


revoke all
on function
public.finalize_prediction_recovery_authorization_internal(
    uuid,
    timestamptz,
    text
)
from public, anon, authenticated;

grant execute
on function
public.finalize_prediction_recovery_authorization_internal(
    uuid,
    timestamptz,
    text
)
to service_role;


revoke all
on function public.close_my_prediction_recovery_rpc(uuid)
from public, anon;

grant execute
on function public.close_my_prediction_recovery_rpc(uuid)
to authenticated, service_role;


revoke all
on function public.expire_due_prediction_recoveries_internal(timestamptz)
from public, anon, authenticated;

grant execute
on function public.expire_due_prediction_recoveries_internal(timestamptz)
to service_role;


-- ============================================================================
-- F. HARD INSTALLATION CONTRACT
-- ============================================================================

do $verification$
declare
    v_guard text;
    v_finalize text;
    v_member_close text;
    v_expire text;
begin

    select pg_get_functiondef(
        'public.guard_strategy_recovery_version_write_internal()'::regprocedure
    )
    into v_guard;


    select pg_get_functiondef(
        'public.finalize_prediction_recovery_authorization_internal(uuid,timestamp with time zone,text)'::regprocedure
    )
    into v_finalize;


    select pg_get_functiondef(
        'public.close_my_prediction_recovery_rpc(uuid)'::regprocedure
    )
    into v_member_close;


    select pg_get_functiondef(
        'public.expire_due_prediction_recoveries_internal(timestamp with time zone)'::regprocedure
    )
    into v_expire;


    if v_guard is null
       or v_finalize is null
       or v_member_close is null
       or v_expire is null then

        raise exception
            'PREDICTION_RECOVERY_CLOSE_COMPONENT_MISSING';
    end if;


    if position(
        'STRATEGY_RECOVERY_WRITE_WINDOW_CLOSED'
        in v_guard
    ) = 0 then

        raise exception
            'STRATEGY_RECOVERY_TERMINAL_WRITE_GUARD_MISSING';
    end if;


    if position(
        'prediction-recovery-member:'
        in v_finalize
    ) = 0 then

        raise exception
            'PREDICTION_RECOVERY_CLOSE_COMMON_LOCK_MISSING';
    end if;


    if position(
        'strategy-recovery-save:'
        in v_finalize
    ) = 0
       or position(
        'strategy-recovery-submit:'
        in v_finalize
    ) = 0 then

        raise exception
            'STRATEGY_RECOVERY_CLOSE_SERIALIZATION_MISSING';
    end if;


    if position(
        'PREDICTION_RECOVERY_NOT_COMPLETE'
        in v_finalize
    ) = 0 then

        raise exception
            'PREDICTION_RECOVERY_EARLY_CLOSE_GATE_MISSING';
    end if;


    if position(
        'recovery_close_void_unsubmitted'
        in v_finalize
    ) = 0 then

        raise exception
            'PREDICTION_RECOVERY_CLOSE_VOID_MISSING';
    end if;


    if position(
        'recovery_close_auto_submit'
        in v_finalize
    ) = 0
       or position(
        'recovery_close_lock_auto_submitted'
        in v_finalize
    ) = 0
       or position(
        'recovery_close_lock_official'
        in v_finalize
    ) = 0 then

        raise exception
            'STRATEGY_RECOVERY_CLOSE_TERMINALIZATION_MISSING';
    end if;


    if position(
        '''expired'''
        in v_finalize
    ) = 0
       or position(
        '''used'''
        in v_finalize
    ) = 0 then

        raise exception
            'PREDICTION_RECOVERY_TERMINAL_STATUS_MISSING';
    end if;


    if position(
        'finalize_prediction_recovery_authorization_internal'
        in v_member_close
    ) = 0
       or position(
        'finalize_prediction_recovery_authorization_internal'
        in v_expire
    ) = 0 then

        raise exception
            'PREDICTION_RECOVERY_CLOSE_DELEGATION_MISSING';
    end if;

end;
$verification$;


commit;