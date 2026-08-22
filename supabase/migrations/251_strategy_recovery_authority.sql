-- ============================================================================
-- FANTAGOL
-- MIGRATION 251
-- STRATEGY RECOVERY AUTHORITY
--
-- R40-R13C2-B
--
-- Depends on migration 250.
--
-- Contract:
--
-- * Prediction Recovery remains the primary authorization authority.
-- * When a Prediction Recovery authorization is created, Strategy Recovery
--   automatically materializes a complete canonical workspace for:
--       - fantacalcio
--       - one_to_one
--
-- * Strategy is NEVER missing during Recovery.
--
-- * Every Recovery Strategy payload remains a COMPLETE ten-match payload.
--
-- * Matches no longer recoverable are FROZEN.
-- * Matches still recoverable are EDITABLE.
--
-- * Frozen values are compared server-side with the immutable Recovery
--   baseline. The client cannot retroactively mutate already-started matches.
--
-- * Fantacalcio:
--       frozen match -> department cannot change.
--
-- * One-to-One:
--       every pairing involving a frozen own/opponent match remains exactly
--       equal to the baseline pairing.
--
-- * Standard Strategy RPCs remain untouched.
-- ============================================================================

begin;


-- ============================================================================
-- A. RECOVERY SCOPE
-- ============================================================================

create or replace function public.get_strategy_recovery_scope_internal(
    p_league_round_id uuid,
    p_league_member_id uuid,
    p_at timestamptz default clock_timestamp()
)
returns table (
    authorization_id uuid,
    authorization_status text,
    authorization_expires_at timestamptz,
    match_id uuid,
    kickoff timestamptz,
    editable boolean
)
language sql
stable
security definer
set search_path to public, pg_temp
as $function$

    with active_authorization as (
        select
            pra.id,
            pra.status,
            pra.expires_at
        from public.prediction_recovery_authorizations pra
        where pra.league_round_id = p_league_round_id
          and pra.target_member_id = p_league_member_id
          and pra.status = 'open'
          and pra.expires_at > p_at
        order by pra.opened_at desc
        limit 1
    )

    select
        aa.id,
        aa.status,
        aa.expires_at,
        scope.match_id,
        scope.kickoff,

        (
            scope.recoverable
            and scope.kickoff > p_at
            and aa.expires_at > p_at
        ) as editable

    from active_authorization aa

    cross join lateral
        public.get_prediction_recovery_match_scope_internal(
            p_league_round_id,
            p_at
        ) scope

    order by scope.kickoff, scope.match_id;

$function$;


comment on function
public.get_strategy_recovery_scope_internal(uuid,uuid,timestamptz)
is
'Internal Strategy Recovery edit-scope resolver. Consumes the open Prediction Recovery authorization and canonical match Recovery authority from migration 250.';


-- ============================================================================
-- B. MATERIALIZE IMMUTABLE RECOVERY BASELINE
-- ============================================================================

create or replace function public.materialize_strategy_recovery_defaults_internal(
    p_authorization_id uuid
)
returns table (
    authorization_id uuid,
    league_round_id uuid,
    league_member_id uuid,
    materialized_modes integer,
    created_strategies integer,
    rebound_strategies integer,
    materialized_at timestamptz
)
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
    v_authorization public.prediction_recovery_authorizations%rowtype;

    v_league_id uuid;
    v_user_id uuid;

    v_mode text;
    v_fixture_id uuid;

    v_strategy public.strategies%rowtype;
    v_strategy_exists boolean := false;

    v_baseline_payload jsonb;
    v_existing_payload jsonb;

    v_next_version integer;

    v_modes integer := 0;
    v_created integer := 0;
    v_rebound integer := 0;

    v_now timestamptz := clock_timestamp();
begin

    select pra.*
    into v_authorization
    from public.prediction_recovery_authorizations pra
    where pra.id = p_authorization_id
    for update;

    if not found then
        raise exception using
            errcode = 'P0001',
            message = 'STRATEGY_RECOVERY_AUTHORIZATION_NOT_FOUND';
    end if;


    if v_authorization.status <> 'open'
       or v_authorization.expires_at <= v_now then
        raise exception using
            errcode = 'P0001',
            message = 'STRATEGY_RECOVERY_AUTHORIZATION_NOT_ACTIVE';
    end if;


    select
        lr.league_id,
        lm.user_id
    into
        v_league_id,
        v_user_id
    from public.league_rounds lr
    join public.league_members lm
      on lm.id = v_authorization.target_member_id
     and lm.league_id = lr.league_id
     and lm.status = 'active'
    where lr.id = v_authorization.league_round_id
      and lr.enabled = true;


    if v_league_id is null then
        raise exception using
            errcode = 'P0001',
            message = 'STRATEGY_RECOVERY_MEMBER_NOT_ACTIVE';
    end if;


    perform pg_advisory_xact_lock(
        hashtextextended(
            'strategy-recovery-materialize:' ||
            v_authorization.league_round_id::text ||
            ':' ||
            v_authorization.target_member_id::text,
            0
        )
    );


    foreach v_mode in array array[
        'fantacalcio'::text,
        'one_to_one'::text
    ]
    loop

        select lf.id
        into v_fixture_id
        from public.league_fixtures lf
        join public.league_schedule_versions lsv
          on lsv.id = lf.schedule_version_id
         and lsv.active = true
        where lf.league_id = v_league_id
          and lf.league_round_id =
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


        v_modes := v_modes + 1;


        select s.*
        into v_strategy
        from public.strategies s
        where s.league_fixture_id = v_fixture_id
          and s.league_member_id =
              v_authorization.target_member_id
        for update;

        v_strategy_exists := found;


        /*
         * Baseline precedence:
         *
         * 1. latest locked payload
         * 2. official submitted payload
         * 3. current pre-Recovery workspace
         * 4. canonical deterministic default
         */
        v_existing_payload := null;


        if v_strategy_exists then

            select sv.payload
            into v_existing_payload
            from public.strategy_versions sv
            where sv.strategy_id = v_strategy.id
              and sv.status = 'locked'
            order by sv.version desc
            limit 1;


            if v_existing_payload is null
               and v_strategy.submitted_version is not null then

                select sv.payload
                into v_existing_payload
                from public.strategy_versions sv
                where sv.strategy_id = v_strategy.id
                  and sv.version =
                      v_strategy.submitted_version;
            end if;


            if v_existing_payload is null then

                select sv.payload
                into v_existing_payload
                from public.strategy_versions sv
                where sv.strategy_id = v_strategy.id
                  and sv.version = v_strategy.version;
            end if;
        end if;


        v_baseline_payload :=
            coalesce(
                v_existing_payload,
                public.build_canonical_default_strategy_payload(
                    v_authorization.league_round_id,
                    v_mode
                )
            );


        perform public.validate_strategy_submission_payload(
            v_mode,
            v_baseline_payload,
            v_authorization.league_round_id
        );


        /*
         * Idempotency:
         * this exact authorization may materialize each mode only once.
         */
        if v_strategy_exists
           and exists (
                select 1
                from public.strategy_versions sv
                where sv.strategy_id = v_strategy.id
                  and sv.source = 'admin_recovery'
                  and sv.metadata ->> 'operation' =
                      'recovery_baseline_materialized'
                  and sv.metadata ->> 'recovery_authorization_id' =
                      v_authorization.id::text
           ) then

            continue;
        end if;


        if v_strategy_exists then

            v_next_version := v_strategy.version + 1;

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
                v_next_version,
                v_baseline_payload,
                'draft',
                'admin_recovery',
                null,
                null,
                v_now,
                jsonb_build_object(
                    'operation',
                        'recovery_baseline_materialized',

                    'recovery_authorization_id',
                        v_authorization.id,

                    'mode',
                        v_mode,

                    'league_round_id',
                        v_authorization.league_round_id,

                    'league_fixture_id',
                        v_fixture_id,

                    'baseline_source',
                        case
                            when v_existing_payload is null
                            then 'canonical_default'
                            else 'pre_recovery_strategy'
                        end
                )
            );


            update public.strategies s
            set
                status = 'draft',
                source = 'admin_recovery',
                version = v_next_version,
                locked_at = null,
                updated_at = v_now
            where s.id = v_strategy.id;


            v_rebound := v_rebound + 1;

        else

            insert into public.strategies (
                league_id,
                league_round_id,
                league_member_id,
                user_id,
                league_fixture_id,
                status,
                source,
                version,
                created_at,
                updated_at
            )
            values (
                v_league_id,
                v_authorization.league_round_id,
                v_authorization.target_member_id,
                v_user_id,
                v_fixture_id,
                'draft',
                'admin_recovery',
                1,
                v_now,
                v_now
            )
            returning *
            into v_strategy;


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
                1,
                v_baseline_payload,
                'draft',
                'admin_recovery',
                null,
                null,
                v_now,
                jsonb_build_object(
                    'operation',
                        'recovery_baseline_materialized',

                    'recovery_authorization_id',
                        v_authorization.id,

                    'mode',
                        v_mode,

                    'league_round_id',
                        v_authorization.league_round_id,

                    'league_fixture_id',
                        v_fixture_id,

                    'baseline_source',
                        'canonical_default'
                )
            );


            v_created := v_created + 1;

        end if;

    end loop;


    return query
    select
        v_authorization.id,
        v_authorization.league_round_id,
        v_authorization.target_member_id,
        v_modes,
        v_created,
        v_rebound,
        v_now;

end;
$function$;


comment on function
public.materialize_strategy_recovery_defaults_internal(uuid)
is
'Materializes one complete immutable Strategy Recovery baseline per required mode for a Prediction Recovery authorization. Missing Strategy falls back to canonical default.';


-- ============================================================================
-- C. AUTHORIZATION INSERT TRIGGER
-- ============================================================================

create or replace function public.materialize_strategy_recovery_on_authorization()
returns trigger
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
begin

    if new.status = 'open' then
        perform *
        from public.materialize_strategy_recovery_defaults_internal(
            new.id
        );
    end if;

    return new;

end;
$function$;


drop trigger if exists
materialize_strategy_recovery_on_authorization_trg
on public.prediction_recovery_authorizations;


create trigger
materialize_strategy_recovery_on_authorization_trg
after insert
on public.prediction_recovery_authorizations
for each row
execute function
public.materialize_strategy_recovery_on_authorization();


-- ============================================================================
-- D. BASELINE RESOLVER
-- ============================================================================

create or replace function public.get_strategy_recovery_baseline_payload_internal(
    p_authorization_id uuid,
    p_mode text
)
returns jsonb
language plpgsql
stable
security definer
set search_path to public, pg_temp
as $function$
declare
    v_payload jsonb;
begin

    if p_mode not in ('fantacalcio', 'one_to_one') then
        raise exception using
            errcode = 'P0001',
            message = 'STRATEGY_MODE_INVALID';
    end if;


    select sv.payload
    into v_payload

    from public.prediction_recovery_authorizations pra

    join public.league_fixtures lf
      on lf.league_round_id = pra.league_round_id
     and lf.mode = p_mode
     and lf.is_bye = false
     and (
          lf.home_member_id = pra.target_member_id
       or lf.away_member_id = pra.target_member_id
     )

    join public.league_schedule_versions lsv
      on lsv.id = lf.schedule_version_id
     and lsv.active = true

    join public.strategies s
      on s.league_fixture_id = lf.id
     and s.league_member_id = pra.target_member_id

    join public.strategy_versions sv
      on sv.strategy_id = s.id
     and sv.source = 'admin_recovery'
     and sv.metadata ->> 'operation' =
         'recovery_baseline_materialized'
     and sv.metadata ->> 'recovery_authorization_id' =
         pra.id::text

    where pra.id = p_authorization_id

    order by sv.version
    limit 1;


    if v_payload is null then
        raise exception using
            errcode = 'P0001',
            message = 'STRATEGY_RECOVERY_BASELINE_NOT_FOUND';
    end if;


    return v_payload;

end;
$function$;


-- ============================================================================
-- E. HARD RECOVERY PAYLOAD VALIDATION
-- ============================================================================

create or replace function public.validate_strategy_recovery_payload_internal(
    p_authorization_id uuid,
    p_mode text,
    p_payload jsonb,
    p_at timestamptz default clock_timestamp()
)
returns void
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
    v_authorization public.prediction_recovery_authorizations%rowtype;

    v_baseline jsonb;

    v_frozen_count integer;
    v_changed_frozen integer;
begin

    select pra.*
    into v_authorization
    from public.prediction_recovery_authorizations pra
    where pra.id = p_authorization_id;


    if not found
       or v_authorization.status <> 'open'
       or v_authorization.expires_at <= p_at then

        raise exception using
            errcode = 'P0001',
            message = 'STRATEGY_RECOVERY_AUTHORIZATION_NOT_ACTIVE';
    end if;


    /*
     * Candidate is ALWAYS a complete normal Strategy payload.
     */
    perform public.validate_strategy_submission_payload(
        p_mode,
        p_payload,
        v_authorization.league_round_id
    );


    v_baseline :=
        public.get_strategy_recovery_baseline_payload_internal(
            p_authorization_id,
            p_mode
        );


    /*
     * FANTACALCIO
     *
     * Every frozen match keeps its baseline department.
     */
    if p_mode = 'fantacalcio' then

        with frozen as (
            select scope.match_id
            from public.get_strategy_recovery_scope_internal(
                v_authorization.league_round_id,
                v_authorization.target_member_id,
                p_at
            ) scope
            where not scope.editable
        ),

        baseline_allocations as (
            select
                (item ->> 'match_id')::uuid as match_id,
                item ->> 'department' as department
            from jsonb_array_elements(
                v_baseline -> 'allocations'
            ) item
        ),

        candidate_allocations as (
            select
                (item ->> 'match_id')::uuid as match_id,
                item ->> 'department' as department
            from jsonb_array_elements(
                p_payload -> 'allocations'
            ) item
        )

        select
            count(*)::integer,

            count(*) filter (
                where ca.department is distinct from
                      ba.department
            )::integer

        into
            v_frozen_count,
            v_changed_frozen

        from frozen f

        join baseline_allocations ba
          on ba.match_id = f.match_id

        join candidate_allocations ca
          on ca.match_id = f.match_id;


        if coalesce(v_changed_frozen, 0) > 0 then
            raise exception using
                errcode = 'P0001',
                message = 'STRATEGY_RECOVERY_FROZEN_MATCH_MUTATION';
        end if;


        return;
    end if;


    /*
     * ONE-TO-ONE
     *
     * Every baseline pairing involving a frozen own OR opponent match
     * must survive exactly:
     *
     * position + own_match_id + opponent_match_id.
     *
     * This prevents a future match from being swapped through an already
     * consumed pairing.
     */
    with frozen as (
        select scope.match_id
        from public.get_strategy_recovery_scope_internal(
            v_authorization.league_round_id,
            v_authorization.target_member_id,
            p_at
        ) scope
        where not scope.editable
    ),

    baseline_pairings as (
        select
            (item ->> 'position')::integer as position,
            (item ->> 'own_match_id')::uuid as own_match_id,
            (item ->> 'opponent_match_id')::uuid as opponent_match_id
        from jsonb_array_elements(
            v_baseline -> 'pairings'
        ) item
    ),

    candidate_pairings as (
        select
            (item ->> 'position')::integer as position,
            (item ->> 'own_match_id')::uuid as own_match_id,
            (item ->> 'opponent_match_id')::uuid as opponent_match_id
        from jsonb_array_elements(
            p_payload -> 'pairings'
        ) item
    ),

    protected_baseline as (
        select distinct bp.*
        from baseline_pairings bp
        where exists (
            select 1
            from frozen f
            where f.match_id = bp.own_match_id
               or f.match_id = bp.opponent_match_id
        )
    )

    select
        count(*)::integer,

        count(*) filter (
            where cp.position is null
        )::integer

    into
        v_frozen_count,
        v_changed_frozen

    from protected_baseline pb

    left join candidate_pairings cp
      on cp.position = pb.position
     and cp.own_match_id = pb.own_match_id
     and cp.opponent_match_id =
         pb.opponent_match_id;


    if coalesce(v_changed_frozen, 0) > 0 then
        raise exception using
            errcode = 'P0001',
            message = 'STRATEGY_RECOVERY_FROZEN_PAIRING_MUTATION';
    end if;

end;
$function$;


comment on function
public.validate_strategy_recovery_payload_internal(uuid,text,jsonb,timestamptz)
is
'Validates a complete Recovery Strategy payload and rejects every mutation of the dynamically frozen match subset.';


-- ============================================================================
-- F. MEMBER WORKSPACE READ MODEL
-- ============================================================================

create or replace function public.get_my_strategy_recovery_workspace_rpc(
    p_league_round_id uuid,
    p_mode text
)
returns table (
    league_round_id uuid,
    league_member_id uuid,
    league_fixture_id uuid,
    mode text,

    authorization_id uuid,
    authorization_expires_at timestamptz,

    strategy_id uuid,
    workspace_version integer,
    workspace_payload jsonb,

    editable_match_ids uuid[],
    frozen_match_ids uuid[],

    editable_match_count integer,
    frozen_match_count integer,

    recovery_active boolean,
    is_editable boolean
)
language plpgsql
security definer
set search_path to public, pg_temp
as $function$
declare
    v_user_id uuid := auth.uid();

    v_member_id uuid;
    v_league_id uuid;

    v_authorization_id uuid;
    v_expires_at timestamptz;

    v_fixture_id uuid;

    v_strategy public.strategies%rowtype;
    v_payload jsonb;

    v_editable_ids uuid[];
    v_frozen_ids uuid[];

    v_now timestamptz := clock_timestamp();
begin

    if v_user_id is null then
        raise exception using
            errcode = 'P0001',
            message = 'USER_NOT_AUTHENTICATED';
    end if;


    if p_mode not in ('fantacalcio', 'one_to_one') then
        raise exception using
            errcode = 'P0001',
            message = 'STRATEGY_MODE_INVALID';
    end if;


    select lr.league_id
    into v_league_id
    from public.league_rounds lr
    where lr.id = p_league_round_id
      and lr.enabled = true;


    if v_league_id is null then
        raise exception using
            errcode = 'P0001',
            message = 'STRATEGY_ROUND_NOT_FOUND';
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
            message = 'STRATEGY_ACTIVE_MEMBERSHIP_REQUIRED';
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
            message = 'STRATEGY_RECOVERY_NOT_ACTIVE';
    end if;


    select lf.id
    into v_fixture_id
    from public.league_fixtures lf
    join public.league_schedule_versions lsv
      on lsv.id = lf.schedule_version_id
     and lsv.active = true
    where lf.league_id = v_league_id
      and lf.league_round_id = p_league_round_id
      and lf.mode = p_mode
      and lf.is_bye = false
      and (
           lf.home_member_id = v_member_id
        or lf.away_member_id = v_member_id
      )
    limit 1;


    if v_fixture_id is null then
        raise exception using
            errcode = 'P0001',
            message = 'STRATEGY_ACTIVE_FIXTURE_NOT_FOUND';
    end if;


    select s.*
    into v_strategy
    from public.strategies s
    where s.league_fixture_id = v_fixture_id
      and s.league_member_id = v_member_id;


    if not found then
        /*
         * Defensive fallback: authorization trigger should already have
         * materialized the Recovery default.
         */
        perform *
        from public.materialize_strategy_recovery_defaults_internal(
            v_authorization_id
        );


        select s.*
        into v_strategy
        from public.strategies s
        where s.league_fixture_id = v_fixture_id
          and s.league_member_id = v_member_id;
    end if;


    if v_strategy.id is null then
        raise exception using
            errcode = 'P0001',
            message = 'STRATEGY_RECOVERY_WORKSPACE_NOT_FOUND';
    end if;


    select sv.payload
    into v_payload
    from public.strategy_versions sv
    where sv.strategy_id = v_strategy.id
      and sv.version = v_strategy.version;


    select
        coalesce(
            array_agg(scope.match_id order by scope.kickoff, scope.match_id)
            filter (where scope.editable),
            array[]::uuid[]
        ),

        coalesce(
            array_agg(scope.match_id order by scope.kickoff, scope.match_id)
            filter (where not scope.editable),
            array[]::uuid[]
        )

    into
        v_editable_ids,
        v_frozen_ids

    from public.get_strategy_recovery_scope_internal(
        p_league_round_id,
        v_member_id,
        v_now
    ) scope;


    return query
    select
        p_league_round_id,
        v_member_id,
        v_fixture_id,
        p_mode,

        v_authorization_id,
        v_expires_at,

        v_strategy.id,
        v_strategy.version,
        v_payload,

        v_editable_ids,
        v_frozen_ids,

        cardinality(v_editable_ids),
        cardinality(v_frozen_ids),

        true,
        cardinality(v_editable_ids) > 0;

end;
$function$;


-- ============================================================================
-- G. SAVE RECOVERY WORKSPACE
-- ============================================================================

create or replace function public.save_strategy_recovery_draft_rpc(
    p_league_round_id uuid,
    p_mode text,
    p_payload jsonb
)
returns table (
    strategy_id uuid,
    league_fixture_id uuid,
    mode text,
    workspace_version integer,
    editable_match_count integer,
    frozen_match_count integer,
    saved_at timestamptz
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

    v_fixture_id uuid;
    v_strategy public.strategies%rowtype;

    v_next_version integer;

    v_editable_count integer;
    v_frozen_count integer;

    v_now timestamptz := clock_timestamp();
begin

    if v_user_id is null then
        raise exception using
            errcode = 'P0001',
            message = 'USER_NOT_AUTHENTICATED';
    end if;


    if p_mode not in ('fantacalcio', 'one_to_one') then
        raise exception using
            errcode = 'P0001',
            message = 'STRATEGY_MODE_INVALID';
    end if;


    select lr.league_id
    into v_league_id
    from public.league_rounds lr
    where lr.id = p_league_round_id
      and lr.enabled = true;


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
            message = 'STRATEGY_ACTIVE_MEMBERSHIP_REQUIRED';
    end if;


    select pra.id
    into v_authorization_id
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
            message = 'STRATEGY_RECOVERY_NOT_ACTIVE';
    end if;


    perform pg_advisory_xact_lock(
        hashtextextended(
            'strategy-recovery-save:' ||
            p_league_round_id::text ||
            ':' ||
            v_member_id::text ||
            ':' ||
            p_mode,
            0
        )
    );


    perform public.validate_strategy_recovery_payload_internal(
        v_authorization_id,
        p_mode,
        p_payload,
        v_now
    );


    select lf.id
    into v_fixture_id
    from public.league_fixtures lf
    join public.league_schedule_versions lsv
      on lsv.id = lf.schedule_version_id
     and lsv.active = true
    where lf.league_id = v_league_id
      and lf.league_round_id = p_league_round_id
      and lf.mode = p_mode
      and lf.is_bye = false
      and (
           lf.home_member_id = v_member_id
        or lf.away_member_id = v_member_id
      )
    limit 1;


    select s.*
    into v_strategy
    from public.strategies s
    where s.league_fixture_id = v_fixture_id
      and s.league_member_id = v_member_id
    for update;


    if not found then
        raise exception using
            errcode = 'P0001',
            message = 'STRATEGY_RECOVERY_WORKSPACE_NOT_FOUND';
    end if;


    v_next_version := v_strategy.version + 1;


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
        v_next_version,
        p_payload,
        'draft',
        'admin_recovery',
        v_user_id,
        v_member_id,
        v_now,
        jsonb_build_object(
            'operation',
                'recovery_workspace_save',

            'recovery_authorization_id',
                v_authorization_id,

            'mode',
                p_mode,

            'league_round_id',
                p_league_round_id,

            'league_fixture_id',
                v_fixture_id
        )
    );


    update public.strategies s
    set
        status = 'draft',
        source = 'admin_recovery',
        version = v_next_version,
        updated_at = v_now
    where s.id = v_strategy.id;


    select
        count(*) filter (where scope.editable)::integer,
        count(*) filter (where not scope.editable)::integer
    into
        v_editable_count,
        v_frozen_count
    from public.get_strategy_recovery_scope_internal(
        p_league_round_id,
        v_member_id,
        v_now
    ) scope;


    return query
    select
        v_strategy.id,
        v_fixture_id,
        p_mode,
        v_next_version,
        v_editable_count,
        v_frozen_count,
        v_now;

end;
$function$;


-- ============================================================================
-- H. SUBMIT RECOVERY STRATEGY
--
-- Optional for the user.
-- R13C3 will implement automatic submission/default certification at relock.
-- ============================================================================

create or replace function public.submit_strategy_recovery_rpc(
    p_league_round_id uuid,
    p_mode text
)
returns table (
    strategy_id uuid,
    league_fixture_id uuid,
    mode text,
    workspace_version integer,
    submitted_version integer,
    official_submitted_at timestamptz,
    already_submitted boolean
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

    v_fixture_id uuid;
    v_strategy public.strategies%rowtype;

    v_payload jsonb;
    v_new_version integer;

    v_now timestamptz := clock_timestamp();
begin

    if v_user_id is null then
        raise exception using
            errcode = 'P0001',
            message = 'USER_NOT_AUTHENTICATED';
    end if;


    if p_mode not in ('fantacalcio', 'one_to_one') then
        raise exception using
            errcode = 'P0001',
            message = 'STRATEGY_MODE_INVALID';
    end if;


    select lr.league_id
    into v_league_id
    from public.league_rounds lr
    where lr.id = p_league_round_id
      and lr.enabled = true;


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
            message = 'STRATEGY_ACTIVE_MEMBERSHIP_REQUIRED';
    end if;


    select pra.id
    into v_authorization_id
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
            message = 'STRATEGY_RECOVERY_NOT_ACTIVE';
    end if;


    perform pg_advisory_xact_lock(
        hashtextextended(
            'strategy-recovery-submit:' ||
            p_league_round_id::text ||
            ':' ||
            v_member_id::text ||
            ':' ||
            p_mode,
            0
        )
    );


    select lf.id
    into v_fixture_id
    from public.league_fixtures lf
    join public.league_schedule_versions lsv
      on lsv.id = lf.schedule_version_id
     and lsv.active = true
    where lf.league_id = v_league_id
      and lf.league_round_id = p_league_round_id
      and lf.mode = p_mode
      and lf.is_bye = false
      and (
           lf.home_member_id = v_member_id
        or lf.away_member_id = v_member_id
      )
    limit 1;


    select s.*
    into v_strategy
    from public.strategies s
    where s.league_fixture_id = v_fixture_id
      and s.league_member_id = v_member_id
    for update;


    if not found then
        raise exception using
            errcode = 'P0001',
            message = 'STRATEGY_RECOVERY_WORKSPACE_NOT_FOUND';
    end if;


    if v_strategy.submitted_version is not null
       and v_strategy.submitted_version = v_strategy.version
       and v_strategy.status = 'submitted'
       and v_strategy.source = 'admin_recovery' then

        return query
        select
            v_strategy.id,
            v_fixture_id,
            p_mode,
            v_strategy.version,
            v_strategy.submitted_version,
            v_strategy.official_submitted_at,
            true;

        return;
    end if;


    select sv.payload
    into v_payload
    from public.strategy_versions sv
    where sv.strategy_id = v_strategy.id
      and sv.version = v_strategy.version;


    perform public.validate_strategy_recovery_payload_internal(
        v_authorization_id,
        p_mode,
        v_payload,
        v_now
    );


    v_new_version := v_strategy.version + 1;


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
        v_new_version,
        v_payload,
        'submitted',
        'admin_recovery',
        v_user_id,
        v_member_id,
        v_now,
        jsonb_build_object(
            'operation',
                'recovery_submit',

            'recovery_authorization_id',
                v_authorization_id,

            'mode',
                p_mode,

            'league_round_id',
                p_league_round_id,

            'league_fixture_id',
                v_fixture_id,

            'workspace_source_version',
                v_strategy.version
        )
    );


    update public.strategies s
    set
        status = 'submitted',
        source = 'admin_recovery',
        version = v_new_version,
        submitted_version = v_new_version,
        submitted_at = v_now,
        official_submitted_at = v_now,
        updated_at = v_now
    where s.id = v_strategy.id
    returning s.*
    into v_strategy;


    return query
    select
        v_strategy.id,
        v_fixture_id,
        p_mode,
        v_strategy.version,
        v_strategy.submitted_version,
        v_strategy.official_submitted_at,
        false;

end;
$function$;


-- ============================================================================
-- I. SECURITY
-- ============================================================================

revoke all
on function public.get_strategy_recovery_scope_internal(uuid,uuid,timestamptz)
from public, anon, authenticated;

grant execute
on function public.get_strategy_recovery_scope_internal(uuid,uuid,timestamptz)
to service_role;


revoke all
on function public.materialize_strategy_recovery_defaults_internal(uuid)
from public, anon, authenticated;

grant execute
on function public.materialize_strategy_recovery_defaults_internal(uuid)
to service_role;


revoke all
on function public.materialize_strategy_recovery_on_authorization()
from public, anon, authenticated;


revoke all
on function public.get_strategy_recovery_baseline_payload_internal(uuid,text)
from public, anon, authenticated;

grant execute
on function public.get_strategy_recovery_baseline_payload_internal(uuid,text)
to service_role;


revoke all
on function public.validate_strategy_recovery_payload_internal(uuid,text,jsonb,timestamptz)
from public, anon, authenticated;

grant execute
on function public.validate_strategy_recovery_payload_internal(uuid,text,jsonb,timestamptz)
to service_role;


revoke all
on function public.get_my_strategy_recovery_workspace_rpc(uuid,text)
from public, anon;

grant execute
on function public.get_my_strategy_recovery_workspace_rpc(uuid,text)
to authenticated, service_role;


revoke all
on function public.save_strategy_recovery_draft_rpc(uuid,text,jsonb)
from public, anon;

grant execute
on function public.save_strategy_recovery_draft_rpc(uuid,text,jsonb)
to authenticated, service_role;


revoke all
on function public.submit_strategy_recovery_rpc(uuid,text)
from public, anon;

grant execute
on function public.submit_strategy_recovery_rpc(uuid,text)
to authenticated, service_role;


-- ============================================================================
-- J. HARD INSTALLATION CONTRACT
-- ============================================================================

do $verification$
declare
    v_scope text;
    v_materializer text;
    v_validator text;
    v_workspace text;
    v_save text;
    v_submit text;
begin

    select pg_get_functiondef(
        'public.get_strategy_recovery_scope_internal(uuid,uuid,timestamp with time zone)'::regprocedure
    )
    into v_scope;

    select pg_get_functiondef(
        'public.materialize_strategy_recovery_defaults_internal(uuid)'::regprocedure
    )
    into v_materializer;

    select pg_get_functiondef(
        'public.validate_strategy_recovery_payload_internal(uuid,text,jsonb,timestamp with time zone)'::regprocedure
    )
    into v_validator;

    select pg_get_functiondef(
        'public.get_my_strategy_recovery_workspace_rpc(uuid,text)'::regprocedure
    )
    into v_workspace;

    select pg_get_functiondef(
        'public.save_strategy_recovery_draft_rpc(uuid,text,jsonb)'::regprocedure
    )
    into v_save;

    select pg_get_functiondef(
        'public.submit_strategy_recovery_rpc(uuid,text)'::regprocedure
    )
    into v_submit;


    if v_scope is null
       or v_materializer is null
       or v_validator is null
       or v_workspace is null
       or v_save is null
       or v_submit is null then

        raise exception
            'STRATEGY_RECOVERY_AUTHORITY_COMPONENT_MISSING';
    end if;


    if position(
        'get_prediction_recovery_match_scope_internal'
        in v_scope
    ) = 0 then
        raise exception
            'STRATEGY_RECOVERY_PREDICTION_SCOPE_BRIDGE_MISSING';
    end if;


    if position(
        'build_canonical_default_strategy_payload'
        in v_materializer
    ) = 0 then
        raise exception
            'STRATEGY_RECOVERY_DEFAULT_FALLBACK_MISSING';
    end if;


    if position(
        'recovery_baseline_materialized'
        in v_materializer
    ) = 0 then
        raise exception
            'STRATEGY_RECOVERY_BASELINE_MISSING';
    end if;


    if position(
        'STRATEGY_RECOVERY_FROZEN_MATCH_MUTATION'
        in v_validator
    ) = 0 then
        raise exception
            'FANTACALCIO_RECOVERY_FREEZE_MISSING';
    end if;


    if position(
        'STRATEGY_RECOVERY_FROZEN_PAIRING_MUTATION'
        in v_validator
    ) = 0 then
        raise exception
            'ONE_TO_ONE_RECOVERY_FREEZE_MISSING';
    end if;


    if position(
        '''admin_recovery'''
        in v_save
    ) = 0
       or position(
        '''admin_recovery'''
        in v_submit
    ) = 0 then
        raise exception
            'STRATEGY_RECOVERY_SOURCE_MISSING';
    end if;

end;
$verification$;


commit;