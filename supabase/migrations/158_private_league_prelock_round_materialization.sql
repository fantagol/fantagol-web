-- ============================================================================
-- FANTAGOL
-- MIGRATION 158
-- GENERIC LEAGUE ROUND MATERIALIZATION CORE
-- AND PRIVATE PRE-LOCK MATERIALIZATION
--
-- Purpose:
--   - extract the shared League Round materialization algorithm;
--   - preserve the certified public materialization contract;
--   - materialize newly created private leagues before roster lock;
--   - preserve the open roster lifecycle;
--   - remain idempotent and compatible with lock_league_roster_rpc.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. GENERIC INTERNAL MATERIALIZATION CORE
-- ----------------------------------------------------------------------------

create or replace function public.materialize_league_rounds_core(
  target_league_id uuid,
  expected_visibility text
)
returns integer
language plpgsql
security definer
set search_path to public
as $function$
declare
  v_league public.leagues%rowtype;
  v_start_round public.fantagol_rounds%rowtype;
  v_visibility text;
  v_error_prefix text;
  v_affected_count integer := 0;
begin
  if target_league_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_REQUIRED';
  end if;

  v_visibility := lower(nullif(trim(expected_visibility), ''));

  if v_visibility is null
     or v_visibility not in ('public', 'private') then
    raise exception using
      errcode = 'P0001',
      message = 'INVALID_LEAGUE_VISIBILITY';
  end if;

  v_error_prefix :=
    case
      when v_visibility = 'public' then 'PUBLIC_LEAGUE'
      else 'PRIVATE_LEAGUE'
    end;

  select l.*
  into v_league
  from public.leagues l
  where l.id = target_league_id;

  if v_league.id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_NOT_FOUND';
  end if;

  if v_league.visibility <> v_visibility then
    return 0;
  end if;

  if v_league.starts_from_fantagol_round_id is null then
    raise exception using
      errcode = 'P0001',
      message = v_error_prefix || '_START_ROUND_REQUIRED';
  end if;

  select fr.*
  into v_start_round
  from public.fantagol_rounds fr
  where fr.id = v_league.starts_from_fantagol_round_id
    and fr.edition_id = v_league.edition_id
    and fr.active = true;

  if v_start_round.id is null then
    raise exception using
      errcode = 'P0001',
      message = v_error_prefix || '_START_ROUND_NOT_FOUND';
  end if;

  insert into public.league_rounds (
    league_id,
    fantagol_round_id,
    league_round_number,
    status,
    enabled
  )
  select
    v_league.id,
    fr.id,
    row_number() over (
      order by fr.sequence
    )::integer,
    case
      when fr.id = v_start_round.id
       and clock_timestamp() >= fr.opens_at
       and clock_timestamp() < fr.lock_at
        then 'predictions_open'
      else 'scheduled'
    end,
    true
  from public.fantagol_rounds fr
  where fr.edition_id = v_league.edition_id
    and fr.active = true
    and fr.sequence >= v_start_round.sequence
    and fr.status <> 'cancelled'
  order by fr.sequence
  on conflict on constraint league_rounds_league_fantagol_unique
  do update
  set
    enabled = true,
    status =
      case
        when excluded.fantagol_round_id = v_start_round.id
         and clock_timestamp() >= v_start_round.opens_at
         and clock_timestamp() < v_start_round.lock_at
         and public.league_rounds.status = 'scheduled'
          then 'predictions_open'
        else public.league_rounds.status
      end;

  get diagnostics v_affected_count = row_count;

  return v_affected_count;
end;
$function$;

comment on function public.materialize_league_rounds_core(uuid, text)
is
'Internal idempotent League Round materialization core shared by visibility-specific wrappers.';

revoke all
on function public.materialize_league_rounds_core(uuid, text)
from public, anon, authenticated;

grant execute
on function public.materialize_league_rounds_core(uuid, text)
to postgres, service_role;

-- ----------------------------------------------------------------------------
-- 2. PRESERVE PUBLIC MATERIALIZATION CONTRACT
-- ----------------------------------------------------------------------------

create or replace function public.materialize_public_league_rounds(
  target_league_id uuid
)
returns integer
language plpgsql
security definer
set search_path to public
as $function$
begin
  return public.materialize_league_rounds_core(
    target_league_id,
    'public'
  );
end;
$function$;

comment on function public.materialize_public_league_rounds(uuid)
is
'Idempotently materializes enabled League Rounds for a public league from its canonical starting FantaGol Round while preserving the open roster lifecycle.';

revoke all
on function public.materialize_public_league_rounds(uuid)
from public, anon, authenticated;

grant execute
on function public.materialize_public_league_rounds(uuid)
to service_role;

-- ----------------------------------------------------------------------------
-- 3. PRIVATE MATERIALIZATION WRAPPER
-- ----------------------------------------------------------------------------

create or replace function public.materialize_private_league_rounds(
  target_league_id uuid
)
returns integer
language plpgsql
security definer
set search_path to public
as $function$
begin
  return public.materialize_league_rounds_core(
    target_league_id,
    'private'
  );
end;
$function$;

comment on function public.materialize_private_league_rounds(uuid)
is
'Idempotently materializes enabled League Rounds for a private league from its canonical starting FantaGol Round without locking its roster.';

revoke all
on function public.materialize_private_league_rounds(uuid)
from public, anon, authenticated;

grant execute
on function public.materialize_private_league_rounds(uuid)
to service_role;

-- ----------------------------------------------------------------------------
-- 4. PRIVATE MATERIALIZATION TRIGGER
-- ----------------------------------------------------------------------------

create or replace function public.materialize_private_league_rounds_trigger()
returns trigger
language plpgsql
security definer
set search_path to public
as $function$
begin
  if new.visibility = 'private'
     and new.starts_from_fantagol_round_id is not null
     and (
       tg_op = 'INSERT'
       or old.visibility is distinct from new.visibility
       or old.starts_from_fantagol_round_id
          is distinct from new.starts_from_fantagol_round_id
       or old.edition_id is distinct from new.edition_id
     ) then
    perform public.materialize_private_league_rounds(new.id);
  end if;

  return new;
end;
$function$;

comment on function public.materialize_private_league_rounds_trigger()
is
'Materializes League Rounds whenever a private league receives or changes its canonical starting round.';

drop trigger if exists
  leagues_materialize_private_rounds_trigger
on public.leagues;

create trigger leagues_materialize_private_rounds_trigger
after insert or update of
  visibility,
  starts_from_fantagol_round_id,
  edition_id
on public.leagues
for each row
execute function public.materialize_private_league_rounds_trigger();

-- ----------------------------------------------------------------------------
-- 5. BACKFILL EXISTING ACTIVE PRIVATE LEAGUES
-- ----------------------------------------------------------------------------

do $backfill$
declare
  v_league record;
begin
  for v_league in
    select l.id
    from public.leagues l
    where l.visibility = 'private'
      and l.starts_from_fantagol_round_id is not null
      and l.lifecycle_status not in ('completed', 'archived')
  loop
    perform public.materialize_private_league_rounds(v_league.id);
  end loop;
end;
$backfill$;

-- ----------------------------------------------------------------------------
-- 6. CERTIFICATION
-- ----------------------------------------------------------------------------

do $verification$
declare
  v_missing_private_round_leagues bigint;
  v_invalid_private_first_rounds bigint;
  v_missing_public_round_leagues bigint;
begin
  select count(*)
  into v_missing_private_round_leagues
  from public.leagues l
  where l.visibility = 'private'
    and l.starts_from_fantagol_round_id is not null
    and l.lifecycle_status not in ('completed', 'archived')
    and not exists (
      select 1
      from public.league_rounds lr
      where lr.league_id = l.id
        and lr.enabled = true
        and lr.status not in ('archived', 'cancelled')
    );

  if v_missing_private_round_leagues <> 0 then
    raise exception
      'PRIVATE_LEAGUES_WITHOUT_MATERIALIZED_ROUNDS: %',
      v_missing_private_round_leagues;
  end if;

  select count(*)
  into v_invalid_private_first_rounds
  from public.leagues l
  where l.visibility = 'private'
    and l.starts_from_fantagol_round_id is not null
    and l.lifecycle_status not in ('completed', 'archived')
    and not exists (
      select 1
      from public.league_rounds lr
      where lr.league_id = l.id
        and lr.fantagol_round_id = l.starts_from_fantagol_round_id
        and lr.enabled = true
    );

  if v_invalid_private_first_rounds <> 0 then
    raise exception
      'PRIVATE_LEAGUES_WITHOUT_CANONICAL_FIRST_ROUND: %',
      v_invalid_private_first_rounds;
  end if;

  select count(*)
  into v_missing_public_round_leagues
  from public.leagues l
  where l.visibility = 'public'
    and l.starts_from_fantagol_round_id is not null
    and not exists (
      select 1
      from public.league_rounds lr
      where lr.league_id = l.id
        and lr.enabled = true
        and lr.status not in ('archived', 'cancelled')
    );

  if v_missing_public_round_leagues <> 0 then
    raise exception
      'PUBLIC_LEAGUES_WITHOUT_MATERIALIZED_ROUNDS_AFTER_CORE_EXTRACTION: %',
      v_missing_public_round_leagues;
  end if;

  if not exists (
    select 1
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'materialize_league_rounds_core'
      and pg_get_function_identity_arguments(p.oid) = 'target_league_id uuid, expected_visibility text'
  ) then
    raise exception
      'GENERIC_LEAGUE_ROUND_MATERIALIZATION_CORE_MISSING';
  end if;

  if not exists (
    select 1
    from pg_trigger t
    where t.tgrelid = 'public.leagues'::regclass
      and t.tgname = 'leagues_materialize_public_rounds_trigger'
      and not t.tgisinternal
  ) then
    raise exception
      'PUBLIC_LEAGUE_ROUND_MATERIALIZATION_TRIGGER_MISSING';
  end if;

  if not exists (
    select 1
    from pg_trigger t
    where t.tgrelid = 'public.leagues'::regclass
      and t.tgname = 'leagues_materialize_private_rounds_trigger'
      and not t.tgisinternal
  ) then
    raise exception
      'PRIVATE_LEAGUE_ROUND_MATERIALIZATION_TRIGGER_MISSING';
  end if;

  raise notice
    'FANTAGOL_GENERIC_AND_PRIVATE_LEAGUE_ROUND_MATERIALIZATION_CERTIFIED';
end;
$verification$;

commit;
