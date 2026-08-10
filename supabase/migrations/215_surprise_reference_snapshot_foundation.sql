begin;

-- ================================================================
-- FANTAGOL
-- MIGRATION 215
-- SURPRISE REFERENCE SNAPSHOT FOUNDATION
--
-- PURPOSE
--   Create an immutable, round-scoped reference for the bookmaker
--   odds that define Surprise eligibility when predictions reopen.
--
-- SAFETY
--   - does NOT open prediction windows
--   - does NOT change league_round status
--   - does NOT call external providers
--   - does NOT create Surprise candidates
--   - does NOT modify existing official_match_odds_snapshots
-- ================================================================


-- ================================================================
-- 1. ROUND REFERENCE REGISTRY
-- ================================================================

create table if not exists public.surprise_reference_rounds (
    id uuid primary key default gen_random_uuid(),

    fantagol_round_id uuid not null
        references public.fantagol_rounds(id)
        on delete restrict,

    status text not null default 'building',

    reference_at timestamptz not null,

    policy_version text not null
        default 'surprise_reference_v1',

    required_match_count integer not null default 0,
    captured_match_count integer not null default 0,

    reference_hash text,

    created_at timestamptz not null default now(),
    ready_at timestamptz,

    metadata jsonb not null default '{}'::jsonb,

    constraint surprise_reference_rounds_round_unique
        unique (fantagol_round_id),

    constraint surprise_reference_rounds_status_check
        check (
            status in (
                'building',
                'ready',
                'failed'
            )
        ),

    constraint surprise_reference_rounds_counts_check
        check (
            required_match_count >= 0
            and captured_match_count >= 0
            and captured_match_count <= required_match_count
        ),

    constraint surprise_reference_rounds_ready_contract
        check (
            (
                status = 'ready'
                and ready_at is not null
                and reference_hash is not null
                and btrim(reference_hash) <> ''
                and required_match_count > 0
                and captured_match_count = required_match_count
            )
            or
            status <> 'ready'
        ),

    constraint surprise_reference_rounds_policy_nonempty
        check (
            btrim(policy_version) <> ''
        )
);


create index if not exists
surprise_reference_rounds_status_idx
on public.surprise_reference_rounds (
    status,
    reference_at
);


-- ================================================================
-- 2. IMMUTABLE MATCH REFERENCES
-- ================================================================

create table if not exists public.surprise_reference_matches (
    id uuid primary key default gen_random_uuid(),

    surprise_reference_round_id uuid not null
        references public.surprise_reference_rounds(id)
        on delete restrict,

    fantagol_round_id uuid not null
        references public.fantagol_rounds(id)
        on delete restrict,

    match_id uuid not null
        references public.matches(id)
        on delete restrict,

    odds_market_snapshot_id uuid not null
        references public.odds_market_snapshots(id)
        on delete restrict,

    source_collected_at timestamptz not null,

    source_snapshot_hash text not null,

    consensus_payload jsonb not null,

    quality_payload jsonb not null default '{}'::jsonb,

    created_at timestamptz not null default now(),

    metadata jsonb not null default '{}'::jsonb,

    constraint surprise_reference_matches_round_match_unique
        unique (
            surprise_reference_round_id,
            match_id
        ),

    constraint surprise_reference_matches_round_scope_unique
        unique (
            fantagol_round_id,
            match_id
        ),

    constraint surprise_reference_matches_source_hash_nonempty
        check (
            btrim(source_snapshot_hash) <> ''
        )
);


create index if not exists
surprise_reference_matches_round_idx
on public.surprise_reference_matches (
    fantagol_round_id,
    match_id
);


create index if not exists
surprise_reference_matches_source_idx
on public.surprise_reference_matches (
    odds_market_snapshot_id
);


-- ================================================================
-- 3. IMMUTABILITY GUARDS
-- ================================================================

create or replace function
public.prevent_surprise_reference_match_mutation()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $function$
begin
    raise exception using
        errcode = 'P0001',
        message = 'SURPRISE_REFERENCE_MATCH_IMMUTABLE';
end;
$function$;


drop trigger if exists
surprise_reference_matches_immutable_trigger
on public.surprise_reference_matches;


create trigger
surprise_reference_matches_immutable_trigger
before update or delete
on public.surprise_reference_matches
for each row
execute function
public.prevent_surprise_reference_match_mutation();


create or replace function
public.guard_surprise_reference_round_mutation()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $function$
begin
    if tg_op = 'DELETE' then

        if old.status = 'ready' then
            raise exception using
                errcode = 'P0001',
                message = 'SURPRISE_REFERENCE_ROUND_IMMUTABLE';
        end if;

        return old;
    end if;

    if old.status = 'ready' then

        if new is distinct from old then
            raise exception using
                errcode = 'P0001',
                message = 'SURPRISE_REFERENCE_ROUND_IMMUTABLE';
        end if;

    end if;

    return new;
end;
$function$;


drop trigger if exists
surprise_reference_rounds_guard_trigger
on public.surprise_reference_rounds;


create trigger
surprise_reference_rounds_guard_trigger
before update or delete
on public.surprise_reference_rounds
for each row
execute function
public.guard_surprise_reference_round_mutation();


-- ================================================================
-- 4. BEGIN ROUND REFERENCE
-- ================================================================

create or replace function
public.begin_surprise_reference_round_internal(
    p_fantagol_round_id uuid,
    p_reference_at timestamptz,
    p_policy_version text default 'surprise_reference_v1',
    p_metadata jsonb default '{}'::jsonb
)
returns table (
    surprise_reference_round_id uuid,
    fantagol_round_id uuid,
    reference_at timestamptz,
    required_match_count integer,
    status text,
    already_exists boolean
)
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
    v_existing public.surprise_reference_rounds%rowtype;
    v_required integer;
    v_id uuid;
begin

    if p_fantagol_round_id is null then
        raise exception using
            errcode = 'P0001',
            message = 'SURPRISE_REFERENCE_ROUND_REQUIRED';
    end if;

    if p_reference_at is null then
        raise exception using
            errcode = 'P0001',
            message = 'SURPRISE_REFERENCE_TIME_REQUIRED';
    end if;

    if btrim(coalesce(p_policy_version, '')) = '' then
        raise exception using
            errcode = 'P0001',
            message = 'SURPRISE_REFERENCE_POLICY_REQUIRED';
    end if;

    perform pg_advisory_xact_lock(
        hashtextextended(
            'surprise-reference-round:' ||
            p_fantagol_round_id::text,
            0
        )
    );

    select *
    into v_existing
    from public.surprise_reference_rounds srr
    where srr.fantagol_round_id = p_fantagol_round_id;

    if found then

        return query
        select
            v_existing.id,
            v_existing.fantagol_round_id,
            v_existing.reference_at,
            v_existing.required_match_count,
            v_existing.status,
            true;

        return;
    end if;

    if not exists (
        select 1
        from public.fantagol_rounds fr
        where fr.id = p_fantagol_round_id
          and fr.active = true
          and fr.status <> 'cancelled'
    ) then
        raise exception using
            errcode = 'P0001',
            message = 'SURPRISE_REFERENCE_ROUND_NOT_ELIGIBLE';
    end if;

    select count(*)::integer
    into v_required
    from public.fantagol_round_matches frm
    where frm.fantagol_round_id = p_fantagol_round_id
      and frm.removed_at is null
      and frm.required;

    if coalesce(v_required, 0) <= 0 then
        raise exception using
            errcode = 'P0001',
            message = 'SURPRISE_REFERENCE_MATCH_SET_EMPTY';
    end if;

    insert into public.surprise_reference_rounds (
        fantagol_round_id,
        status,
        reference_at,
        policy_version,
        required_match_count,
        captured_match_count,
        metadata
    )
    values (
        p_fantagol_round_id,
        'building',
        p_reference_at,
        p_policy_version,
        v_required,
        0,
        coalesce(p_metadata, '{}'::jsonb)
    )
    returning id
    into v_id;

    return query
    select
        v_id,
        p_fantagol_round_id,
        p_reference_at,
        v_required,
        'building'::text,
        false;

end;
$function$;


-- ================================================================
-- 5. ATTACH ONE MATCH SNAPSHOT
-- ================================================================

create or replace function
public.attach_surprise_reference_match_internal(
    p_fantagol_round_id uuid,
    p_match_id uuid,
    p_odds_market_snapshot_id uuid,
    p_metadata jsonb default '{}'::jsonb
)
returns table (
    surprise_reference_match_id uuid,
    surprise_reference_round_id uuid,
    match_id uuid,
    odds_market_snapshot_id uuid,
    source_collected_at timestamptz,
    inserted boolean
)
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
    v_round public.surprise_reference_rounds%rowtype;
    v_source public.odds_market_snapshots%rowtype;
    v_existing public.surprise_reference_matches%rowtype;
    v_id uuid;
begin

    if p_fantagol_round_id is null
       or p_match_id is null
       or p_odds_market_snapshot_id is null then

        raise exception using
            errcode = 'P0001',
            message = 'SURPRISE_REFERENCE_MATCH_ARGUMENT_REQUIRED';
    end if;

    perform pg_advisory_xact_lock(
        hashtextextended(
            'surprise-reference-match:' ||
            p_fantagol_round_id::text ||
            ':' ||
            p_match_id::text,
            0
        )
    );

    select *
    into v_round
    from public.surprise_reference_rounds srr
    where srr.fantagol_round_id = p_fantagol_round_id
    for update;

    if not found then
        raise exception using
            errcode = 'P0001',
            message = 'SURPRISE_REFERENCE_ROUND_NOT_STARTED';
    end if;

    if v_round.status <> 'building' then
        raise exception using
            errcode = 'P0001',
            message = 'SURPRISE_REFERENCE_ROUND_NOT_BUILDING';
    end if;

    if not exists (
        select 1
        from public.fantagol_round_matches frm
        where frm.fantagol_round_id = p_fantagol_round_id
          and frm.match_id = p_match_id
          and frm.removed_at is null
          and frm.required
    ) then
        raise exception using
            errcode = 'P0001',
            message = 'SURPRISE_REFERENCE_MATCH_NOT_IN_ROUND';
    end if;

    select *
    into v_existing
    from public.surprise_reference_matches srm
    where srm.surprise_reference_round_id = v_round.id
      and srm.match_id = p_match_id;

    if found then

        return query
        select
            v_existing.id,
            v_existing.surprise_reference_round_id,
            v_existing.match_id,
            v_existing.odds_market_snapshot_id,
            v_existing.source_collected_at,
            false;

        return;
    end if;

    select *
    into v_source
    from public.odds_market_snapshots oms
    where oms.id = p_odds_market_snapshot_id;

    if not found then
        raise exception using
            errcode = 'P0001',
            message = 'SURPRISE_REFERENCE_ODDS_SNAPSHOT_NOT_FOUND';
    end if;

    if v_source.match_id <> p_match_id then
        raise exception using
            errcode = 'P0001',
            message = 'SURPRISE_REFERENCE_ODDS_MATCH_MISMATCH';
    end if;

    if v_source.collected_at > v_round.reference_at then
        raise exception using
            errcode = 'P0001',
            message = 'SURPRISE_REFERENCE_ODDS_AFTER_REFERENCE_TIME';
    end if;

    if v_source.market_code <> 'h2h' then
        raise exception using
            errcode = 'P0001',
            message = 'SURPRISE_REFERENCE_H2H_REQUIRED';
    end if;

    if v_source.consensus_payload is null
       or coalesce(
            (v_source.quality_payload ->> 'hasConsensus')::boolean,
            false
       ) = false then

        raise exception using
            errcode = 'P0001',
            message = 'SURPRISE_REFERENCE_CONSENSUS_REQUIRED';
    end if;

    insert into public.surprise_reference_matches (
        surprise_reference_round_id,
        fantagol_round_id,
        match_id,
        odds_market_snapshot_id,
        source_collected_at,
        source_snapshot_hash,
        consensus_payload,
        quality_payload,
        metadata
    )
    values (
        v_round.id,
        p_fantagol_round_id,
        p_match_id,
        v_source.id,
        v_source.collected_at,
        v_source.snapshot_hash,
        v_source.consensus_payload,
        v_source.quality_payload,
        coalesce(p_metadata, '{}'::jsonb)
    )
    returning id
    into v_id;

    update public.surprise_reference_rounds srr
    set captured_match_count = (
        select count(*)::integer
        from public.surprise_reference_matches srm
        where srm.surprise_reference_round_id = srr.id
    )
    where srr.id = v_round.id;

    return query
    select
        v_id,
        v_round.id,
        p_match_id,
        v_source.id,
        v_source.collected_at,
        true;

end;
$function$;


-- ================================================================
-- 6. FINALIZE AND CERTIFY ROUND REFERENCE
-- ================================================================

create or replace function
public.finalize_surprise_reference_round_internal(
    p_fantagol_round_id uuid
)
returns table (
    surprise_reference_round_id uuid,
    fantagol_round_id uuid,
    required_match_count integer,
    captured_match_count integer,
    reference_hash text,
    status text,
    already_ready boolean
)
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
declare
    v_round public.surprise_reference_rounds%rowtype;
    v_count integer;
    v_hash text;
begin

    if p_fantagol_round_id is null then
        raise exception using
            errcode = 'P0001',
            message = 'SURPRISE_REFERENCE_ROUND_REQUIRED';
    end if;

    perform pg_advisory_xact_lock(
        hashtextextended(
            'surprise-reference-finalize:' ||
            p_fantagol_round_id::text,
            0
        )
    );

    select *
    into v_round
    from public.surprise_reference_rounds srr
    where srr.fantagol_round_id = p_fantagol_round_id
    for update;

    if not found then
        raise exception using
            errcode = 'P0001',
            message = 'SURPRISE_REFERENCE_ROUND_NOT_STARTED';
    end if;

    if v_round.status = 'ready' then

        return query
        select
            v_round.id,
            v_round.fantagol_round_id,
            v_round.required_match_count,
            v_round.captured_match_count,
            v_round.reference_hash,
            v_round.status,
            true;

        return;
    end if;

    if v_round.status <> 'building' then
        raise exception using
            errcode = 'P0001',
            message = 'SURPRISE_REFERENCE_ROUND_NOT_BUILDING';
    end if;

    select count(*)::integer
    into v_count
    from public.surprise_reference_matches srm
    where srm.surprise_reference_round_id = v_round.id;

    if v_count <> v_round.required_match_count then
        raise exception using
            errcode = 'P0001',
            message = 'SURPRISE_REFERENCE_INCOMPLETE',
            detail = format(
                'required=%s captured=%s',
                v_round.required_match_count,
                v_count
            );
    end if;

    if exists (
        select 1
        from public.fantagol_round_matches frm
        where frm.fantagol_round_id = p_fantagol_round_id
          and frm.removed_at is null
          and frm.required
          and not exists (
              select 1
              from public.surprise_reference_matches srm
              where srm.surprise_reference_round_id = v_round.id
                and srm.match_id = frm.match_id
          )
    ) then
        raise exception using
            errcode = 'P0001',
            message = 'SURPRISE_REFERENCE_MATCH_COVERAGE_INCOMPLETE';
    end if;

    select encode(
        extensions.digest(
            convert_to(
                jsonb_build_object(
                    'policy_version',
                    v_round.policy_version,

                    'fantagol_round_id',
                    v_round.fantagol_round_id,

                    'reference_at',
                    v_round.reference_at,

                    'matches',
                    coalesce(
                        jsonb_agg(
                            jsonb_build_object(
                                'match_id',
                                srm.match_id,

                                'odds_market_snapshot_id',
                                srm.odds_market_snapshot_id,

                                'source_collected_at',
                                srm.source_collected_at,

                                'source_snapshot_hash',
                                srm.source_snapshot_hash
                            )
                            order by srm.match_id
                        ),
                        '[]'::jsonb
                    )
                )::text,
                'UTF8'
            ),
            'sha256'
        ),
        'hex'
    )
    into v_hash
    from public.surprise_reference_matches srm
    where srm.surprise_reference_round_id = v_round.id;

    update public.surprise_reference_rounds
    set
        status = 'ready',
        captured_match_count = v_count,
        reference_hash = v_hash,
        ready_at = clock_timestamp()
    where id = v_round.id;

    return query
    select
        v_round.id,
        v_round.fantagol_round_id,
        v_round.required_match_count,
        v_count,
        v_hash,
        'ready'::text,
        false;

end;
$function$;


-- ================================================================
-- 7. READINESS CONTRACT
-- ================================================================

create or replace function
public.surprise_reference_ready_internal(
    p_fantagol_round_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $function$

    select exists (
        select 1
        from public.surprise_reference_rounds srr
        where srr.fantagol_round_id = p_fantagol_round_id
          and srr.status = 'ready'
          and srr.reference_hash is not null
          and srr.captured_match_count =
              srr.required_match_count
          and srr.required_match_count > 0
    );

$function$;


create or replace function
public.get_surprise_reference_status_internal(
    p_fantagol_round_id uuid
)
returns table (
    fantagol_round_id uuid,
    status text,
    reference_at timestamptz,
    required_match_count integer,
    captured_match_count integer,
    reference_hash text,
    ready_at timestamptz,
    ready boolean
)
language sql
stable
security definer
set search_path = public, pg_temp
as $function$

    select
        srr.fantagol_round_id,
        srr.status,
        srr.reference_at,
        srr.required_match_count,
        srr.captured_match_count,
        srr.reference_hash,
        srr.ready_at,
        (
            srr.status = 'ready'
            and srr.reference_hash is not null
            and srr.required_match_count > 0
            and srr.captured_match_count =
                srr.required_match_count
        ) as ready
    from public.surprise_reference_rounds srr
    where srr.fantagol_round_id =
        p_fantagol_round_id;

$function$;


-- ================================================================
-- 8. COMMENTS
-- ================================================================

comment on table
public.surprise_reference_rounds
is
'Round-scoped immutable-after-ready registry for the bookmaker snapshot reference used by the FantaGol Surprise bonus.';


comment on table
public.surprise_reference_matches
is
'Immutable per-match odds snapshot references captured before prediction opening for Surprise eligibility.';


comment on function
public.begin_surprise_reference_round_internal(
    uuid,
    timestamptz,
    text,
    jsonb
)
is
'Starts an idempotent Surprise reference build for one FantaGol Round.';


comment on function
public.attach_surprise_reference_match_internal(
    uuid,
    uuid,
    uuid,
    jsonb
)
is
'Attaches one validated pre-reference H2H odds snapshot to the Surprise reference round.';


comment on function
public.finalize_surprise_reference_round_internal(uuid)
is
'Certifies a complete Surprise reference round and freezes its deterministic hash.';


comment on function
public.surprise_reference_ready_internal(uuid)
is
'Returns true only when a complete certified Surprise reference exists for the FantaGol Round.';


-- ================================================================
-- 9. SECURITY
-- ================================================================

alter table
public.surprise_reference_rounds
enable row level security;

alter table
public.surprise_reference_matches
enable row level security;


revoke all
on public.surprise_reference_rounds
from public, anon, authenticated;

revoke all
on public.surprise_reference_matches
from public, anon, authenticated;


revoke all
on function
public.begin_surprise_reference_round_internal(
    uuid,
    timestamptz,
    text,
    jsonb
)
from public, anon, authenticated;

revoke all
on function
public.attach_surprise_reference_match_internal(
    uuid,
    uuid,
    uuid,
    jsonb
)
from public, anon, authenticated;

revoke all
on function
public.finalize_surprise_reference_round_internal(uuid)
from public, anon, authenticated;

revoke all
on function
public.surprise_reference_ready_internal(uuid)
from public, anon, authenticated;

revoke all
on function
public.get_surprise_reference_status_internal(uuid)
from public, anon, authenticated;


grant select, insert, update
on public.surprise_reference_rounds
to service_role;

grant select, insert
on public.surprise_reference_matches
to service_role;


grant execute
on function
public.begin_surprise_reference_round_internal(
    uuid,
    timestamptz,
    text,
    jsonb
)
to service_role;

grant execute
on function
public.attach_surprise_reference_match_internal(
    uuid,
    uuid,
    uuid,
    jsonb
)
to service_role;

grant execute
on function
public.finalize_surprise_reference_round_internal(uuid)
to service_role;

grant execute
on function
public.surprise_reference_ready_internal(uuid)
to service_role;

grant execute
on function
public.get_surprise_reference_status_internal(uuid)
to service_role;


-- ================================================================
-- 10. MIGRATION ASSERTIONS
-- ================================================================

do $block$
begin

    if to_regclass(
        'public.surprise_reference_rounds'
    ) is null then
        raise exception
            'MIGRATION_215_ROUND_TABLE_MISSING';
    end if;

    if to_regclass(
        'public.surprise_reference_matches'
    ) is null then
        raise exception
            'MIGRATION_215_MATCH_TABLE_MISSING';
    end if;

    if to_regprocedure(
        'public.begin_surprise_reference_round_internal(uuid,timestamp with time zone,text,jsonb)'
    ) is null then
        raise exception
            'MIGRATION_215_BEGIN_FUNCTION_MISSING';
    end if;

    if to_regprocedure(
        'public.attach_surprise_reference_match_internal(uuid,uuid,uuid,jsonb)'
    ) is null then
        raise exception
            'MIGRATION_215_ATTACH_FUNCTION_MISSING';
    end if;

    if to_regprocedure(
        'public.finalize_surprise_reference_round_internal(uuid)'
    ) is null then
        raise exception
            'MIGRATION_215_FINALIZE_FUNCTION_MISSING';
    end if;

    if to_regprocedure(
        'public.surprise_reference_ready_internal(uuid)'
    ) is null then
        raise exception
            'MIGRATION_215_READINESS_FUNCTION_MISSING';
    end if;

end;
$block$;

commit;