-- ============================================================================
-- FANTAGOL
-- MIGRATION 147
-- PUBLIC LEAGUE ROUND MATERIALIZATION FOUNDATION
--
-- Milestone 12.9.4.5
--
-- Purpose:
--   - materialize League Rounds immediately for public leagues;
--   - make newly created public leagues readable by
--     get_my_current_league_round_rpc before roster lock;
--   - preserve the open roster lifecycle;
--   - remain idempotent and compatible with lock_league_roster_rpc.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. IDEMPOTENT PUBLIC LEAGUE ROUND MATERIALIZER
-- ----------------------------------------------------------------------------

create or replace function public.materialize_public_league_rounds(
  target_league_id uuid
)
returns integer
language plpgsql
security definer
set search_path to public
as $function$
declare
  v_league public.leagues%rowtype;
  v_start_round public.fantagol_rounds%rowtype;
  v_inserted_count integer := 0;
begin
  if target_league_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_REQUIRED';
  end if;

  select l.*
  into v_league
  from public.leagues l
  where l.id = target_league_id;

  if v_league.id is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEAGUE_NOT_FOUND';
  end if;

  if v_league.visibility <> 'public' then
    return 0;
  end if;

  if v_league.starts_from_fantagol_round_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'PUBLIC_LEAGUE_START_ROUND_REQUIRED';
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
      message = 'PUBLIC_LEAGUE_START_ROUND_NOT_FOUND';
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

  get diagnostics v_inserted_count = row_count;

  return v_inserted_count;
end;
$function$;

comment on function public.materialize_public_league_rounds(uuid)
is
'Idempotently materializes enabled League Rounds for a public league from its canonical starting FantaGol Round while preserving the open roster lifecycle.';

revoke all
on function public.materialize_public_league_rounds(uuid)
from public;

revoke all
on function public.materialize_public_league_rounds(uuid)
from anon;

revoke all
on function public.materialize_public_league_rounds(uuid)
from authenticated;

grant execute
on function public.materialize_public_league_rounds(uuid)
to service_role;

-- ----------------------------------------------------------------------------
-- 2. AUTOMATIC MATERIALIZATION TRIGGER
-- ----------------------------------------------------------------------------

create or replace function public.materialize_public_league_rounds_trigger()
returns trigger
language plpgsql
security definer
set search_path to public
as $function$
begin
  if new.visibility = 'public'
     and new.starts_from_fantagol_round_id is not null
     and (
       tg_op = 'INSERT'
       or old.visibility is distinct from new.visibility
       or old.starts_from_fantagol_round_id
          is distinct from new.starts_from_fantagol_round_id
       or old.edition_id is distinct from new.edition_id
     ) then
    perform public.materialize_public_league_rounds(new.id);
  end if;

  return new;
end;
$function$;

drop trigger if exists
  leagues_materialize_public_rounds_trigger
on public.leagues;

create trigger leagues_materialize_public_rounds_trigger
after insert or update of
  visibility,
  starts_from_fantagol_round_id,
  edition_id
on public.leagues
for each row
execute function public.materialize_public_league_rounds_trigger();

comment on function public.materialize_public_league_rounds_trigger()
is
'Materializes League Rounds whenever a public league receives or changes its canonical starting round.';

-- ----------------------------------------------------------------------------
-- 3. BACKFILL EXISTING PUBLIC LEAGUES
-- ----------------------------------------------------------------------------

do $backfill$
declare
  v_league record;
begin
  for v_league in
    select l.id
    from public.leagues l
    where l.visibility = 'public'
      and l.starts_from_fantagol_round_id is not null
  loop
    perform public.materialize_public_league_rounds(v_league.id);
  end loop;
end;
$backfill$;

-- ----------------------------------------------------------------------------
-- 4. CERTIFICATION
-- ----------------------------------------------------------------------------

do $verification$
declare
  v_missing_round_leagues bigint;
  v_invalid_first_rounds bigint;
begin
  select count(*)
  into v_missing_round_leagues
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

  if v_missing_round_leagues <> 0 then
    raise exception
      'PUBLIC_LEAGUES_WITHOUT_MATERIALIZED_ROUNDS: %',
      v_missing_round_leagues;
  end if;

  select count(*)
  into v_invalid_first_rounds
  from public.leagues l
  where l.visibility = 'public'
    and l.starts_from_fantagol_round_id is not null
    and not exists (
      select 1
      from public.league_rounds lr
      where lr.league_id = l.id
        and lr.fantagol_round_id = l.starts_from_fantagol_round_id
        and lr.enabled = true
    );

  if v_invalid_first_rounds <> 0 then
    raise exception
      'PUBLIC_LEAGUES_WITHOUT_CANONICAL_FIRST_ROUND: %',
      v_invalid_first_rounds;
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

  raise notice
    'PUBLIC_LEAGUE_ROUND_MATERIALIZATION_FOUNDATION_OK';
end;
$verification$;

commit;