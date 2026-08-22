begin;

-- ============================================================================
-- FANTAGOL - MIGRATION 254
-- PREDICTION RECOVERY MULTI-WINDOW AUTHORITY
--
-- Recovery is governed by temporal kickoff windows:
--
--   * historical USED / EXPIRED / REVOKED rows remain retained;
--   * only one OPEN authorization may exist per member / League Round;
--   * a new window may open after a previous window becomes terminal;
--   * no new window may open while any required match is materially live;
--   * the editable scope remains ALL required matches with kickoff > now;
--   * expires_at is the NEXT recoverable kickoff;
--   * later kickoff blocks may be recovered in subsequent windows.
--
-- Migrations 250-253 remain immutable.
-- ============================================================================


-- ============================================================================
-- 1. STORAGE AUTHORITY
-- ============================================================================

alter table public.prediction_recovery_authorizations
    drop constraint if exists
    prediction_recovery_member_round_unique;

create unique index if not exists
    prediction_recovery_open_member_round_unique
on public.prediction_recovery_authorizations (
    league_round_id,
    target_member_id
)
where status = 'open';


-- ============================================================================
-- 2. ACTIVE LIVE PHASE AUTHORITY
-- ============================================================================

create or replace function public.is_prediction_recovery_live_match_status_internal(
    p_status text
)
returns boolean
language sql
immutable
strict
security invoker
set search_path = public
as $$
    select p_status in (
        'live_first_half',
        'halftime',
        'live_second_half',
        'extra_time',
        'penalties'
    );
$$;

comment on function public.is_prediction_recovery_live_match_status_internal(text)
is
'Canonical classifier for a materially active match phase during which Prediction Recovery cannot be opened.';


create or replace function public.has_active_prediction_recovery_live_phase_internal(
    p_league_round_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select exists (
        select 1

        from public.league_rounds lr

        join public.fantagol_round_matches frm
          on frm.fantagol_round_id =
             lr.fantagol_round_id
         and frm.required
         and frm.removed_at is null

        join public.matches m
          on m.id = frm.match_id

        where lr.id = p_league_round_id

          and public.is_prediction_recovery_live_match_status_internal(
              m.status
          )
    );
$$;

comment on function public.has_active_prediction_recovery_live_phase_internal(uuid)
is
'True while at least one required match in the League Round is materially live.';


revoke all on function
    public.is_prediction_recovery_live_match_status_internal(text)
from public;

revoke all on function
    public.is_prediction_recovery_live_match_status_internal(text)
from anon;

revoke all on function
    public.is_prediction_recovery_live_match_status_internal(text)
from authenticated;

grant execute on function
    public.is_prediction_recovery_live_match_status_internal(text)
to service_role;


revoke all on function
    public.has_active_prediction_recovery_live_phase_internal(uuid)
from public;

revoke all on function
    public.has_active_prediction_recovery_live_phase_internal(uuid)
from anon;

revoke all on function
    public.has_active_prediction_recovery_live_phase_internal(uuid)
from authenticated;

grant execute on function
    public.has_active_prediction_recovery_live_phase_internal(uuid)
to service_role;


-- ============================================================================
-- 3. ADMIN RECOVERY READ MODEL
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
    v_user_id uuid;
    v_league_id uuid;
    v_round_status text;

    v_caller_member_id uuid;
    v_caller_role text;

    v_active_member_count integer := 0;
    v_delivered_member_count integer := 0;
    v_missing_member_count integer := 0;

    v_required_match_count integer := 0;
    v_recoverable_match_count integer := 0;
    v_unrecoverable_count integer := 0;

    v_existing_authorization_count integer := 0;

    v_last_recoverable_kickoff timestamptz;

    v_recovery_available boolean := false;
    v_can_open boolean := false;

    v_now timestamptz := clock_timestamp();
begin

    v_user_id := auth.uid();

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

    limit 1;


    if v_caller_member_id is null then
        raise exception using
            errcode = 'P0001',
            message = 'ACTIVE_LEAGUE_MEMBERSHIP_REQUIRED';
    end if;


    select count(*)::integer
    into v_active_member_count

    from public.league_members lm

    where lm.league_id = v_league_id
      and lm.status = 'active';


    select count(*)::integer
    into v_delivered_member_count

    from public.league_members lm

    where lm.league_id = v_league_id
      and lm.status = 'active'

      and public.has_complete_official_prediction_grid_internal(
          p_league_round_id,
          lm.id
      );


    v_missing_member_count :=
        greatest(
            v_active_member_count -
            v_delivered_member_count,
            0
        );


    select
        count(*)::integer,

        count(*) filter (
            where scope.recoverable
        )::integer,

        count(*) filter (
            where not scope.recoverable
        )::integer,

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


    select count(*)::integer
    into v_existing_authorization_count

    from public.prediction_recovery_authorizations pra

    where pra.league_round_id = p_league_round_id
      and pra.status = 'open';


    /*
     * Recovery exists only AFTER normal Prediction locking.
     *
     * We explicitly allow live/waiting_postponed because the motivating use
     * case is an Admin noticing a missing user after one or more anticipi.
     *
     * Terminal/certification states remain excluded.
     */
    v_recovery_available :=
        v_round_status in (
            'predictions_locked',
            'live',
            'waiting_postponed'
        )

        and v_missing_member_count > 0
        and v_recoverable_match_count > 0

        /*
         * The round/member authorization key is one-shot.
         * Repeated Recovery grants are deliberately excluded in R13C1.
         */
        and v_existing_authorization_count = 0
      and not public.has_active_prediction_recovery_live_phase_internal(
          p_league_round_id
      );


    /*
     * Product authority:
     * ONLY ADMIN. Vice is NOT authorized.
     */
    v_can_open :=
        v_caller_role = 'admin'
        and v_recovery_available;


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
'Authenticated Recovery availability read model. Recovery is unavailable when every active member owns a complete official grid or no future required match remains. Only the active League Admin may receive can_open_recovery=true; Vice and ordinary members never do.';


-- ============================================================================
-- D. ADMIN COMMAND:
--    OPEN RECOVERY FOR ALL AND ONLY MISSING MEMBERS
--
-- The Admin supplies only the League Round.
--
-- NO member selection.
-- NO match selection.
-- ============================================================================



-- ============================================================================
-- 4. OPEN RECOVERY COMMAND
-- ============================================================================


create or replace function public.open_missing_predictions_recovery_rpc(
    p_league_round_id uuid,
    p_reason text default null
)
returns table (
    league_id uuid,
    league_round_id uuid,

    opened_by_member_id uuid,

    authorization_count integer,
    missing_member_count integer,

    recoverable_match_count integer,
    excluded_started_match_count integer,

    expires_at timestamptz,

    already_opened boolean
)
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
    v_user_id uuid;
    v_league_id uuid;
    v_round_status text;

    v_admin_member_id uuid;

    v_active_member_count integer;
    v_delivered_member_count integer;
    v_missing_member_count integer;

    v_recoverable_match_count integer;
    v_required_match_count integer;
    v_excluded_count integer;

    v_expires_at timestamptz;

    v_existing_count integer := 0;
    v_inserted_count integer := 0;

    v_now timestamptz := clock_timestamp();
begin

    v_user_id := auth.uid();

    if v_user_id is null then
        raise exception using
            errcode = 'P0001',
            message = 'AUTH_REQUIRED';
    end if;


    /*
     * Serialize one Recovery-opening decision per League Round.
     */
    perform pg_advisory_xact_lock(
        hashtextextended(
            'prediction-recovery-open:' ||
            p_league_round_id::text,
            0
        )
    );


    select
        lr.league_id,
        lr.status

    into
        v_league_id,
        v_round_status

    from public.league_rounds lr

    where lr.id = p_league_round_id
      and lr.enabled

    for update;


    if v_league_id is null then
        raise exception using
            errcode = 'P0001',
            message = 'LEAGUE_ROUND_NOT_FOUND';
    end if;


    /*
     * HARD AUTHORITY:
     * active Admin only.
     *
     * Vice is intentionally rejected.
     */
    select lm.id
    into v_admin_member_id

    from public.league_members lm

    where lm.league_id = v_league_id
      and lm.user_id = v_user_id
      and lm.status = 'active'
      and lm.role = 'admin'

    limit 1;


    if v_admin_member_id is null then
        raise exception using
            errcode = 'P0001',
            message = 'LEAGUE_ADMIN_REQUIRED';
    end if;


    if v_round_status not in (
        'predictions_locked',
        'live',
        'waiting_postponed'
    ) then
        raise exception using
            errcode = 'P0001',
            message = 'PREDICTION_RECOVERY_ROUND_NOT_ELIGIBLE',
            detail = format(
                'round_status=%s',
                v_round_status
            );
    end if;


    select count(*)::integer
    into v_active_member_count

    from public.league_members lm

    where lm.league_id = v_league_id
      and lm.status = 'active';


    select count(*)::integer
    into v_delivered_member_count

    from public.league_members lm

    where lm.league_id = v_league_id
      and lm.status = 'active'

      and public.has_complete_official_prediction_grid_internal(
          p_league_round_id,
          lm.id
      );


    v_missing_member_count :=
        greatest(
            v_active_member_count -
            v_delivered_member_count,
            0
        );


    /*
     * 100% delivery:
     * Admin cannot force Recovery.
     */
    if v_missing_member_count = 0 then
        raise exception using
            errcode = 'P0001',
            message = 'PREDICTION_RECOVERY_NOT_NEEDED',
            detail = 'all_active_members_delivered';
    end if;


    select
        count(*)::integer,

        count(*) filter (
            where scope.recoverable
        )::integer,

        count(*) filter (
            where not scope.recoverable
        )::integer,

        min(scope.kickoff) filter (where scope.recoverable)

    into
        v_required_match_count,
        v_recoverable_match_count,
        v_excluded_count,
        v_expires_at

    from public.get_prediction_recovery_match_scope_internal(
        p_league_round_id,
        v_now
    ) scope;


    /*
     * No future match remains:
     * Admin cannot force Recovery.
     */
    if coalesce(v_recoverable_match_count, 0) = 0
       or v_expires_at is null then

        raise exception using
            errcode = 'P0001',
            message = 'PREDICTION_RECOVERY_NO_ELIGIBLE_MATCHES';
    end if;


    /*
     * One-shot Round Recovery.
     *
     * Existing rows mean this Recovery phase was already opened before.
     */
    select count(*)::integer
    into v_existing_count

    from public.prediction_recovery_authorizations pra

    where pra.league_round_id = p_league_round_id
      and pra.status = 'open';


      if public.has_active_prediction_recovery_live_phase_internal(
      p_league_round_id
  ) then
    raise exception using
      message = 'PREDICTION_RECOVERY_LIVE_PHASE_ACTIVE';
  end if;
  if v_existing_count > 0 then

        return query
        select
            v_league_id,
            p_league_round_id,

            v_admin_member_id,

            v_existing_count,
            v_missing_member_count,

            v_recoverable_match_count,
            v_excluded_count,

            v_expires_at,

            true;

        return;
    end if;


    /*
     * Materialize one technical authorization per missing active member.
     *
     * UX remains one Admin button; bookkeeping stays member-scoped as
     * originally designed by migration 011.
     */
    insert into public.prediction_recovery_authorizations (
        league_id,
        league_round_id,
        target_member_id,
        opened_by_member_id,

        status,

        opened_at,
        expires_at,

        reason,

        eligible_match_count,
        excluded_started_match_count,

        created_at,
        updated_at,
        version
    )

    select
        v_league_id,
        p_league_round_id,
        lm.id,
        v_admin_member_id,

        'open',

        v_now,
        v_expires_at,

        nullif(btrim(p_reason), ''),

        v_recoverable_match_count,
        v_excluded_count,

        v_now,
        v_now,
        1

    from public.league_members lm

    where lm.league_id = v_league_id
      and lm.status = 'active'

      and not public.has_complete_official_prediction_grid_internal(
          p_league_round_id,
          lm.id
      );


    get diagnostics v_inserted_count = row_count;


    if v_inserted_count <> v_missing_member_count then
        raise exception using
            errcode = 'P0001',
            message = 'PREDICTION_RECOVERY_AUTHORIZATION_INVARIANT_FAILED',
            detail = format(
                'expected_missing_members=%s inserted_authorizations=%s',
                v_missing_member_count,
                v_inserted_count
            );
    end if;


    /*
     * Governance audit event.
     *
     * One Admin action; individual member authorizations remain technical
     * children of this action.
     */
    perform public.write_league_admin_event(
        v_league_id,
        v_admin_member_id,
        v_user_id,
        'member',
        'prediction_recovery_opened',
        null,
        p_league_round_id,
        jsonb_build_object(
            'missing_member_count',
                v_missing_member_count,

            'authorization_count',
                v_inserted_count,

            'required_match_count',
                v_required_match_count,

            'recoverable_match_count',
                v_recoverable_match_count,

            'excluded_started_match_count',
                v_excluded_count,

            'opened_at',
                v_now,

            'expires_at',
                v_expires_at,

            'reason',
                nullif(btrim(p_reason), ''),

            'scope',
                'all_missing_members_future_required_matches',

            'admin_only',
                true
        )
    );


    return query
    select
        v_league_id,
        p_league_round_id,

        v_admin_member_id,

        v_inserted_count,
        v_missing_member_count,

        v_recoverable_match_count,
        v_excluded_count,

        v_expires_at,

        false;

end;
$function$;


comment on function
public.open_missing_predictions_recovery_rpc(uuid, text)
is
'Admin-only command opening Prediction Recovery for every active member lacking a complete official grid. Members and matches are resolved automatically. Started matches remain excluded. Recovery cannot be forced when delivery is 100% or no future required match remains.';


-- ============================================================================
-- E. SECURITY
-- ============================================================================

revoke all
on function public.has_complete_official_prediction_grid_internal(uuid, uuid)
from public;

revoke all
on function public.has_complete_official_prediction_grid_internal(uuid, uuid)
from anon;

revoke all
on function public.has_complete_official_prediction_grid_internal(uuid, uuid)
from authenticated;

grant execute
on function public.has_complete_official_prediction_grid_internal(uuid, uuid)
to service_role;


revoke all
on function public.get_prediction_recovery_match_scope_internal(uuid, timestamptz)
from public;

revoke all
on function public.get_prediction_recovery_match_scope_internal(uuid, timestamptz)
from anon;

revoke all
on function public.get_prediction_recovery_match_scope_internal(uuid, timestamptz)
from authenticated;

grant execute
on function public.get_prediction_recovery_match_scope_internal(uuid, timestamptz)
to service_role;


revoke all
on function public.get_prediction_recovery_admin_status_rpc(uuid)
from public;

revoke all
on function public.get_prediction_recovery_admin_status_rpc(uuid)
from anon;

grant execute
on function public.get_prediction_recovery_admin_status_rpc(uuid)
to authenticated;

grant execute
on function public.get_prediction_recovery_admin_status_rpc(uuid)
to service_role;


revoke all
on function public.open_missing_predictions_recovery_rpc(uuid, text)
from public;

revoke all
on function public.open_missing_predictions_recovery_rpc(uuid, text)
from anon;

grant execute
on function public.open_missing_predictions_recovery_rpc(uuid, text)
to authenticated;

grant execute
on function public.open_missing_predictions_recovery_rpc(uuid, text)
to service_role;


-- ============================================================================
-- F. INSTALLATION VERIFICATION
-- ============================================================================

do $verification$
declare
    v_admin_status text;
    v_open text;
    v_grid text;
    v_scope text;
begin

    select pg_get_functiondef(
        'public.get_prediction_recovery_admin_status_rpc(uuid)'::regprocedure
    )
    into v_admin_status;

    select pg_get_functiondef(
        'public.open_missing_predictions_recovery_rpc(uuid,text)'::regprocedure
    )
    into v_open;

    select pg_get_functiondef(
        'public.has_complete_official_prediction_grid_internal(uuid,uuid)'::regprocedure
    )
    into v_grid;

    select pg_get_functiondef(
        'public.get_prediction_recovery_match_scope_internal(uuid,timestamp with time zone)'::regprocedure
    )
    into v_scope;


    if v_admin_status is null
       or v_open is null
       or v_grid is null
       or v_scope is null then

        raise exception
            'PREDICTION_RECOVERY_AUTHORITY_COMPONENT_MISSING';
    end if;


    if position(
        'submitted_version'
        in v_grid
    ) = 0
       or position(
        'official_submitted_at'
        in v_grid
    ) = 0 then

        raise exception
            'PREDICTION_RECOVERY_OFFICIAL_GRID_AUTHORITY_MISSING';
    end if;


    if position(
        'm.kickoff > p_at'
        in v_scope
    ) = 0 then

        raise exception
            'PREDICTION_RECOVERY_KICKOFF_GATE_MISSING';
    end if;


    if position(
        'v_caller_role = ''admin'''
        in v_admin_status
    ) = 0 then

        raise exception
            'PREDICTION_RECOVERY_ADMIN_READ_GATE_MISSING';
    end if;


    if position(
        'lm.role = ''admin'''
        in v_open
    ) = 0 then

        raise exception
            'PREDICTION_RECOVERY_ADMIN_WRITE_GATE_MISSING';
    end if;


    if position(
        'PREDICTION_RECOVERY_NOT_NEEDED'
        in v_open
    ) = 0 then

        raise exception
            'PREDICTION_RECOVERY_100_PERCENT_DISABLE_MISSING';
    end if;


    if position(
        'PREDICTION_RECOVERY_NO_ELIGIBLE_MATCHES'
        in v_open
    ) = 0 then

        raise exception
            'PREDICTION_RECOVERY_FUTURE_MATCH_GATE_MISSING';
    end if;


    if position(
        'prediction_recovery_opened'
        in v_open
    ) = 0 then

        raise exception
            'PREDICTION_RECOVERY_ADMIN_AUDIT_EVENT_MISSING';
    end if;

end;
$verification$;





-- ============================================================================
-- 5. PRIVILEGE REASSERTION
-- ============================================================================

revoke all on function
    public.get_prediction_recovery_admin_status_rpc(uuid)
from public;

revoke all on function
    public.get_prediction_recovery_admin_status_rpc(uuid)
from anon;

grant execute on function
    public.get_prediction_recovery_admin_status_rpc(uuid)
to authenticated;

grant execute on function
    public.get_prediction_recovery_admin_status_rpc(uuid)
to service_role;


revoke all on function
    public.open_missing_predictions_recovery_rpc(uuid,text)
from public;

revoke all on function
    public.open_missing_predictions_recovery_rpc(uuid,text)
from anon;

revoke all on function
    public.open_missing_predictions_recovery_rpc(uuid,text)
from authenticated;

grant execute on function
    public.open_missing_predictions_recovery_rpc(uuid,text)
to service_role;


-- ============================================================================
-- 6. INSTALLATION ASSERTIONS
-- ============================================================================

do $migration254$
begin

    if exists (
        select 1
        from pg_constraint
        where conrelid =
              'public.prediction_recovery_authorizations'::regclass
          and conname =
              'prediction_recovery_member_round_unique'
    ) then
        raise exception
            'MIGRATION_254_ONE_SHOT_CONSTRAINT_SURVIVED';
    end if;


    if not exists (
        select 1
        from pg_indexes
        where schemaname = 'public'
          and tablename =
              'prediction_recovery_authorizations'
          and indexname =
              'prediction_recovery_open_member_round_unique'
    ) then
        raise exception
            'MIGRATION_254_OPEN_WINDOW_INDEX_MISSING';
    end if;


    if to_regprocedure(
        'public.is_prediction_recovery_live_match_status_internal(text)'
    ) is null then
        raise exception
            'MIGRATION_254_LIVE_STATUS_HELPER_MISSING';
    end if;


    if to_regprocedure(
        'public.has_active_prediction_recovery_live_phase_internal(uuid)'
    ) is null then
        raise exception
            'MIGRATION_254_LIVE_PHASE_HELPER_MISSING';
    end if;

end;
$migration254$;

commit;