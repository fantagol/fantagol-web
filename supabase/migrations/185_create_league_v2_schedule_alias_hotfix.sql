-- FANTAGOL
-- Migration 180
-- Permanently qualify the schedule result columns consumed by
-- create_league_v2_rpc.
--
-- Fixes:
-- column reference "starts_from_fantagol_round_id" is ambiguous

do $migration$
declare
  v_signature regprocedure :=
    'public.create_league_v2_rpc(text,text,text,integer,integer)'::regprocedure;

  v_definition text;
  v_patched_definition text;

  v_pattern text :=
    'select[[:space:]]+' ||
    'schedule_version,[[:space:]]+' ||
    'starts_from_fantagol_round_id,[[:space:]]+' ||
    'first_useful_kickoff_at[[:space:]]+' ||
    'into[[:space:]]+' ||
    'v_schedule_version,[[:space:]]+' ||
    'v_starts_from_fantagol_round_id,[[:space:]]+' ||
    'v_first_useful_kickoff_at[[:space:]]+' ||
    'from[[:space:]]+public\.resolve_public_league_schedule_internal\([[:space:]]*' ||
    'v_edition_id,[[:space:]]*' ||
    'now\(\)[[:space:]]*' ||
    '\);';

  v_replacement text :=
$replacement$
select
     resolved_schedule.schedule_version,
     resolved_schedule.starts_from_fantagol_round_id,
     resolved_schedule.first_useful_kickoff_at
   into
     v_schedule_version,
     v_starts_from_fantagol_round_id,
     v_first_useful_kickoff_at
   from public.resolve_public_league_schedule_internal(
     v_edition_id,
     now()
   ) as resolved_schedule;
$replacement$;

begin
  select pg_get_functiondef(v_signature)
  into v_definition;

  if position(
    'resolved_schedule.starts_from_fantagol_round_id'
    in v_definition
  ) > 0 then
    raise notice
      'CREATE_LEAGUE_V2_SCHEDULE_ALIAS_HOTFIX=ALREADY_PRESENT';
    return;
  end if;

  v_patched_definition := regexp_replace(
    v_definition,
    v_pattern,
    v_replacement,
    'i'
  );

  if v_patched_definition = v_definition then
    raise exception
      'CREATE_LEAGUE_V2_SCHEDULE_ALIAS_HOTFIX_TARGET_NOT_FOUND';
  end if;

  execute v_patched_definition;

  raise notice
    'CREATE_LEAGUE_V2_SCHEDULE_ALIAS_HOTFIX=APPLIED';
end;
$migration$;

select
  case
    when position(
      'resolved_schedule.starts_from_fantagol_round_id'
      in pg_get_functiondef(
        'public.create_league_v2_rpc(text,text,text,integer,integer)'::regprocedure
      )
    ) > 0
      then 'PASS'
    else 'FAIL'
  end as create_league_v2_schedule_alias_certification;
