begin;

-- ============================================================================
-- FANTAGOL - MIGRATION 257
-- OFFICIAL MATCH ODDS AUTHORITY V2
--
-- PURPOSE
--   Evolve official_match_odds_snapshots from one immutable row per Match
--   into an immutable VERSIONED authority:
--
--       official -> superseded
--
--   Historical evidence remains addressable by UUID forever.
--
-- SAFETY
--   - no deletion of historical evidence
--   - no mutation of odds evidence payload/hash/source
--   - lifecycle-only supersession is permitted
--   - one active OFFICIAL authority per Match
--   - synthetic / test / E2E market evidence can never become OFFICIAL
--   - no scoring
--   - no certification
--   - no job enqueue
-- ============================================================================


-- ============================================================================
-- 1. VERSIONED AUTHORITY COLUMNS
-- ============================================================================

alter table public.official_match_odds_snapshots
    add column if not exists authority_version integer,
    add column if not exists status text,
    add column if not exists superseded_at timestamptz,
    add column if not exists superseded_by_official_odds_snapshot_id uuid,
    add column if not exists supersede_reason text;


create or replace function public.prevent_official_match_odds_mutation()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $function$
begin

    if tg_op = 'DELETE' then
        raise exception using
            errcode = 'P0001',
            message =
                'OFFICIAL_MATCH_ODDS_DELETE_FORBIDDEN';
    end if;


    /*
     * Immutable evidence identity.
     *
     * Every permitted lifecycle transition below MUST preserve
     * the complete original evidence payload.
     */
    if not (
        old.id
            is not distinct from
        new.id

        and old.match_id
            is not distinct from
        new.match_id

        and old.odds_market_snapshot_id
            is not distinct from
        new.odds_market_snapshot_id

        and old.frozen_at
            is not distinct from
        new.frozen_at

        and old.freeze_reason
            is not distinct from
        new.freeze_reason

        and old.policy_version
            is not distinct from
        new.policy_version

        and old.official_hash
            is not distinct from
        new.official_hash

        and old.created_at
            is not distinct from
        new.created_at
    ) then

        raise exception using
            errcode = 'P0001',
            message =
                'OFFICIAL_MATCH_ODDS_IMMUTABLE';

    end if;


    /*
     * Transition A:
     *
     * Existing v1 rows gain lifecycle metadata.
     *
     * No evidence changes.
     */
    if
        old.authority_version is null
        and old.status is null

        and new.authority_version = 1
        and new.status = 'official'

        and new.superseded_at is null
        and
            new.superseded_by_official_odds_snapshot_id
            is null
        and new.supersede_reason is null
    then
        return new;
    end if;


    /*
     * Transition B:
     *
     * Current authority becomes historical.
     *
     * The successor UUID can be attached after INSERT because the
     * new row does not exist yet when partial-unique authority is
     * first released.
     */
    if
        old.status = 'official'
        and new.status = 'superseded'

        and old.authority_version
            is not distinct from
        new.authority_version

        and new.superseded_at is not null

        and new.supersede_reason is not null
        and btrim(new.supersede_reason) <> ''

        and
            new.superseded_by_official_odds_snapshot_id
            is null
    then
        return new;
    end if;


    /*
     * Transition C:
     *
     * Attach the successor exactly once.
     *
     * The row is already SUPERSEDED and all other lifecycle/evidence
     * fields must remain unchanged.
     */
    if
        old.status = 'superseded'
        and new.status = 'superseded'

        and old.authority_version
            is not distinct from
        new.authority_version

        and old.superseded_at
            is not distinct from
        new.superseded_at

        and old.supersede_reason
            is not distinct from
        new.supersede_reason

        and
            old.superseded_by_official_odds_snapshot_id
            is null

        and
            new.superseded_by_official_odds_snapshot_id
            is not null

        and
            new.superseded_by_official_odds_snapshot_id
            <> new.id
    then
        return new;
    end if;


    raise exception using
        errcode = 'P0001',
        message =
            'OFFICIAL_MATCH_ODDS_IMMUTABLE';

end;
$function$;

update public.official_match_odds_snapshots
set
    authority_version = 1,
    status = 'official'
where authority_version is null
   or status is null;


alter table public.official_match_odds_snapshots
    alter column authority_version set not null,
    alter column status set not null;


alter table public.official_match_odds_snapshots
    add constraint official_match_odds_authority_version_positive
    check (authority_version > 0);


alter table public.official_match_odds_snapshots
    add constraint official_match_odds_status_valid
    check (
        status in (
            'official',
            'superseded'
        )
    );


alter table public.official_match_odds_snapshots
    add constraint official_match_odds_superseded_shape
    check (
        (
            status = 'official'
            and superseded_at is null
            and supersede_reason is null
        )
        or
        (
            status = 'superseded'
            and superseded_at is not null
            and supersede_reason is not null
            and btrim(supersede_reason) <> ''
        )
    );


alter table public.official_match_odds_snapshots
    add constraint official_match_odds_superseded_by_fkey
    foreign key (
        superseded_by_official_odds_snapshot_id
    )
    references public.official_match_odds_snapshots(id)
    on delete restrict;


-- ============================================================================
-- 2. REMOVE SINGLETON MATCH CONSTRAINT
-- ============================================================================

alter table public.official_match_odds_snapshots
    drop constraint official_match_odds_snapshots_match_id_key;


create unique index
    official_match_odds_one_active_idx
on public.official_match_odds_snapshots(match_id)
where status = 'official';


create unique index
    official_match_odds_version_idx
on public.official_match_odds_snapshots(
    match_id,
    authority_version
);


-- ============================================================================
-- 3. LIFECYCLE-AWARE IMMUTABILITY GUARD
-- ============================================================================




drop trigger if exists
    official_match_odds_immutable_trigger
on public.official_match_odds_snapshots;


create trigger
    official_match_odds_immutable_trigger
before update or delete
on public.official_match_odds_snapshots
for each row
execute function
    public.prevent_official_match_odds_mutation();


-- ============================================================================
-- 4. SOURCE EVIDENCE VALIDATOR
-- ============================================================================

create or replace function
public.assert_real_official_odds_source_internal(
    p_match_id uuid,
    p_odds_market_snapshot_id uuid
)
returns public.odds_market_snapshots
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
    v_source public.odds_market_snapshots%rowtype;
begin

    select oms.*
    into v_source
    from public.odds_market_snapshots oms
    where oms.id =
          p_odds_market_snapshot_id
      and oms.match_id =
          p_match_id;

    if not found then
        raise exception using
            errcode = 'P0001',
            message =
                'OFFICIAL_ODDS_SOURCE_NOT_FOUND';
    end if;

    if
        v_source.consensus_payload is null
        or
        coalesce(
            (
                v_source.quality_payload
                    ->> 'hasConsensus'
            )::boolean,
            false
        ) <> true
    then
        raise exception using
            errcode = 'P0001',
            message =
                'OFFICIAL_ODDS_SOURCE_NO_CONSENSUS';
    end if;

    if
        coalesce(
            (
                v_source.quality_payload
                    ->> 'synthetic'
            )::boolean,
            false
        )
        or
        nullif(
            v_source.quality_payload
                ->> 'testScope',
            ''
        ) is not null
        or
        coalesce(
            (
                v_source.provider_payload
                    ->> 'synthetic'
            )::boolean,
            false
        )
        or
        nullif(
            v_source.provider_payload
                ->> 'testScope',
            ''
        ) is not null
        or
        v_source.external_match_id
            ilike 'e2e-%'
    then
        raise exception using
            errcode = 'P0001',
            message =
                'SYNTHETIC_OFFICIAL_ODDS_FORBIDDEN';
    end if;

    return v_source;

end;
$function$;


-- ============================================================================
-- 5. ACTIVE AUTHORITY RESOLVER
-- ============================================================================

create or replace function
public.get_active_official_match_odds_snapshot_internal(
    p_match_id uuid
)
returns public.official_match_odds_snapshots
language sql
stable
security definer
set search_path = public, pg_temp
as $function$

    select o
    from public.official_match_odds_snapshots o
    where o.match_id = p_match_id
      and o.status = 'official'
    order by
        o.authority_version desc,
        o.frozen_at desc,
        o.created_at desc,
        o.id desc
    limit 1;

$function$;


-- ============================================================================
-- 6. VERSIONED SUPERSESSION AUTHORITY
-- ============================================================================

create or replace function
public.supersede_official_match_odds_internal(
    p_match_id uuid,
    p_new_odds_market_snapshot_id uuid,
    p_freeze_reason text,
    p_policy_version text,
    p_supersede_reason text,
    p_frozen_at timestamptz default now()
)
returns table (
    old_official_match_odds_snapshot_id uuid,
    new_official_match_odds_snapshot_id uuid,
    new_authority_version integer,
    already_current boolean
)
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
declare
    v_old public.official_match_odds_snapshots%rowtype;
    v_source public.odds_market_snapshots%rowtype;

    v_new_id uuid;
    v_next_version integer;
    v_hash text;
begin

    if p_match_id is null then
        raise exception using
            errcode = '22004',
            message = 'MATCH_ID_REQUIRED';
    end if;

    if p_new_odds_market_snapshot_id is null then
        raise exception using
            errcode = '22004',
            message =
                'ODDS_MARKET_SNAPSHOT_ID_REQUIRED';
    end if;

    if btrim(coalesce(
        p_freeze_reason,
        ''
    )) = '' then
        raise exception using
            errcode = '22023',
            message =
                'FREEZE_REASON_REQUIRED';
    end if;

    if btrim(coalesce(
        p_policy_version,
        ''
    )) = '' then
        raise exception using
            errcode = '22023',
            message =
                'POLICY_VERSION_REQUIRED';
    end if;

    if btrim(coalesce(
        p_supersede_reason,
        ''
    )) = '' then
        raise exception using
            errcode = '22023',
            message =
                'SUPERSEDE_REASON_REQUIRED';
    end if;

    perform pg_advisory_xact_lock(
        hashtextextended(
            'official-match-odds-v2:' ||
            p_match_id::text,
            0
        )
    );

    v_source :=
        public.assert_real_official_odds_source_internal(
            p_match_id,
            p_new_odds_market_snapshot_id
        );

    select o.*
    into v_old
    from public.official_match_odds_snapshots o
    where o.match_id = p_match_id
      and o.status = 'official'
    order by
        o.authority_version desc,
        o.id desc
    limit 1
    for update;

    if
        v_old.id is not null
        and
        v_old.odds_market_snapshot_id =
            p_new_odds_market_snapshot_id
    then

        return query
        select
            v_old.id,
            v_old.id,
            v_old.authority_version,
            true;

        return;
    end if;

    select
        coalesce(
            max(o.authority_version),
            0
        ) + 1
    into v_next_version
    from public.official_match_odds_snapshots o
    where o.match_id =
          p_match_id;

    v_hash :=
        encode(
            digest(
                convert_to(
                    jsonb_build_object(
                        'match_id',
                            p_match_id,
                        'odds_market_snapshot_id',
                            p_new_odds_market_snapshot_id,
                        'snapshot_hash',
                            v_source.snapshot_hash,
                        'collected_at',
                            v_source.collected_at,
                        'authority_version',
                            v_next_version,
                        'policy_version',
                            p_policy_version
                    )::text,
                    'UTF8'
                ),
                'sha256'
            ),
            'hex'
        );

    /*
     * Release the partial unique authority before INSERT.
     * Immutable evidence remains untouched.
     */
    if v_old.id is not null then

        update public.official_match_odds_snapshots
        set
            status = 'superseded',
            superseded_at =
                clock_timestamp(),
            supersede_reason =
                p_supersede_reason
        where id = v_old.id;

    end if;

    insert into public.official_match_odds_snapshots (
        match_id,
        odds_market_snapshot_id,
        frozen_at,
        freeze_reason,
        policy_version,
        official_hash,
        authority_version,
        status
    )
    values (
        p_match_id,
        p_new_odds_market_snapshot_id,
        p_frozen_at,
        p_freeze_reason,
        p_policy_version,
        v_hash,
        v_next_version,
        'official'
    )
    returning id
    into v_new_id;

    if v_old.id is not null then

        update public.official_match_odds_snapshots
        set
            superseded_by_official_odds_snapshot_id =
                v_new_id
        where id = v_old.id;

    end if;

    return query
    select
        v_old.id,
        v_new_id,
        v_next_version,
        false;

end;
$function$;


-- ============================================================================
-- 7. SECURITY
-- ============================================================================

revoke all
on function
public.assert_real_official_odds_source_internal(uuid, uuid)
from public, anon, authenticated;


revoke all
on function
public.get_active_official_match_odds_snapshot_internal(uuid)
from public, anon, authenticated;


revoke all
on function
public.supersede_official_match_odds_internal(
    uuid,
    uuid,
    text,
    text,
    text,
    timestamptz
)
from public, anon, authenticated;


grant execute
on function
public.assert_real_official_odds_source_internal(uuid, uuid)
to service_role;


grant execute
on function
public.get_active_official_match_odds_snapshot_internal(uuid)
to service_role;


grant execute
on function
public.supersede_official_match_odds_internal(
    uuid,
    uuid,
    text,
    text,
    text,
    timestamptz
)
to service_role;


comment on function
public.supersede_official_match_odds_internal(
    uuid,
    uuid,
    text,
    text,
    text,
    timestamptz
)
is
'Versioned Official Match Odds authority. Preserves historical immutable evidence, supersedes only lifecycle state, rejects synthetic/test/E2E market evidence, and installs exactly one active official authority per Match.';


commit;