-- Migration 033: Match Set Foundation Completion
-- Purpose:
--   - materialize the missing official Match Set snapshot for all existing
--     complete FantaGol Rounds;
--   - add an idempotent Round Engine helper that creates the initial official
--     Match Set snapshot when a round reaches its complete active Match Set;
--   - preserve existing validation, immutability and synchronization triggers.
--
-- Ownership:
--   Competition / Round Engine.
--
-- Important:
--   This migration creates only the INITIAL snapshot for a round that has no
--   Match Set versions yet. Future pre-lock Match Set replacements must use a
--   dedicated version-creation command and are intentionally outside this file.

begin;

-- ============================================================
-- 1. INITIAL OFFICIAL MATCH SET MATERIALIZER
-- ============================================================

create or replace function public.ensure_initial_official_match_set_snapshot(
  p_fantagol_round_id uuid,
  p_reason text default 'initial_round_generation'
)
returns table (
  fantagol_round_id uuid,
  created boolean,
  snapshot_version integer,
  match_count integer
)
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_round public.fantagol_rounds%rowtype;
  v_match_ids uuid[];
  v_match_count integer;
  v_distinct_match_count integer;
  v_min_slot integer;
  v_max_slot integer;
  v_distinct_slot_count integer;
begin
  if p_fantagol_round_id is null then
    raise exception using
      errcode = 'P0001',
      message = 'MATCH_SET_ROUND_REQUIRED';
  end if;

  if p_reason is null or btrim(p_reason) = '' then
    raise exception using
      errcode = 'P0001',
      message = 'MATCH_SET_REASON_REQUIRED';
  end if;

  select fr.*
  into v_round
  from public.fantagol_rounds fr
  where fr.id = p_fantagol_round_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'MATCH_SET_ROUND_NOT_FOUND';
  end if;

  -- Initial materialization is idempotent. If any version already exists,
  -- this helper leaves the round untouched.
  if exists (
    select 1
    from public.match_set_versions msv
    where msv.fantagol_round_id = p_fantagol_round_id
  ) then
    return query
    select
      p_fantagol_round_id,
      false,
      v_round.official_match_set_version,
      (
        select count(*)::integer
        from public.fantagol_round_matches frm
        where frm.fantagol_round_id = p_fantagol_round_id
          and frm.removed_at is null
      );
    return;
  end if;

  select
    array_agg(frm.match_id order by frm.slot_number),
    count(*)::integer,
    count(distinct frm.match_id)::integer,
    min(frm.slot_number),
    max(frm.slot_number),
    count(distinct frm.slot_number)::integer
  into
    v_match_ids,
    v_match_count,
    v_distinct_match_count,
    v_min_slot,
    v_max_slot,
    v_distinct_slot_count
  from public.fantagol_round_matches frm
  where frm.fantagol_round_id = p_fantagol_round_id
    and frm.removed_at is null;

  -- A snapshot is created only when the Round Match Set is complete.
  if v_match_count <> v_round.target_match_count then
    return query
    select
      p_fantagol_round_id,
      false,
      null::integer,
      coalesce(v_match_count, 0);
    return;
  end if;

  if v_match_count < v_round.minimum_match_count
     or v_match_count > v_round.maximum_match_count then
    raise exception using
      errcode = 'P0001',
      message = 'MATCH_SET_COUNT_OUTSIDE_ROUND_LIMITS',
      detail = format(
        'count=%s minimum=%s maximum=%s',
        v_match_count,
        v_round.minimum_match_count,
        v_round.maximum_match_count
      );
  end if;

  if v_distinct_match_count <> v_match_count then
    raise exception using
      errcode = 'P0001',
      message = 'MATCH_SET_DUPLICATE_MATCH';
  end if;

  if v_min_slot <> 1
     or v_max_slot <> v_match_count
     or v_distinct_slot_count <> v_match_count then
    raise exception using
      errcode = 'P0001',
      message = 'MATCH_SET_SLOT_SEQUENCE_INVALID',
      detail = format(
        'min_slot=%s max_slot=%s distinct_slots=%s match_count=%s',
        v_min_slot,
        v_max_slot,
        v_distinct_slot_count,
        v_match_count
      );
  end if;

  insert into public.match_set_versions (
    fantagol_round_id,
    version,
    match_ids_ordered,
    reason,
    created_by,
    official
  )
  values (
    p_fantagol_round_id,
    1,
    v_match_ids,
    p_reason,
    null,
    true
  );

  -- sync_official_match_set_version() updates the Round automatically.
  return query
  select
    p_fantagol_round_id,
    true,
    1,
    v_match_count;
end;
$function$;

comment on function public.ensure_initial_official_match_set_snapshot(uuid, text)
is 'Idempotently creates official Match Set version 1 when a FantaGol Round has its complete active slot-ordered Match Set and no prior snapshot.';


-- ============================================================
-- 2. AUTOMATIC INITIAL SNAPSHOT AFTER ROUND MATCH GENERATION
-- ============================================================

create or replace function public.create_initial_match_set_snapshot_after_round_match()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
begin
  perform public.ensure_initial_official_match_set_snapshot(
    new.fantagol_round_id,
    'initial_round_generation'
  );

  return new;
end;
$function$;

comment on function public.create_initial_match_set_snapshot_after_round_match()
is 'Round Engine trigger adapter that materializes the first official Match Set as soon as the configured target match count is reached.';

drop trigger if exists create_initial_match_set_snapshot_after_round_match
  on public.fantagol_round_matches;

create trigger create_initial_match_set_snapshot_after_round_match
after insert or update of
  match_id,
  slot_number,
  removed_at
on public.fantagol_round_matches
for each row
execute function public.create_initial_match_set_snapshot_after_round_match();


-- ============================================================
-- 3. BACKFILL ALL EXISTING COMPLETE ROUNDS
-- ============================================================

do $block$
declare
  v_round_id uuid;
begin
  for v_round_id in
    select fr.id
    from public.fantagol_rounds fr
    where not exists (
      select 1
      from public.match_set_versions msv
      where msv.fantagol_round_id = fr.id
    )
    order by fr.sequence, fr.id
  loop
    perform public.ensure_initial_official_match_set_snapshot(
      v_round_id,
      'foundation_backfill'
    );
  end loop;
end;
$block$;


-- ============================================================
-- 4. POST-BACKFILL ACCEPTANCE GUARDS
-- ============================================================

do $block$
declare
  v_complete_round_count integer;
  v_official_snapshot_count integer;
  v_synced_round_count integer;
  v_invalid_snapshot_count integer;
begin
  select count(*)::integer
  into v_complete_round_count
  from public.fantagol_rounds fr
  where (
    select count(*)
    from public.fantagol_round_matches frm
    where frm.fantagol_round_id = fr.id
      and frm.removed_at is null
  ) = fr.target_match_count;

  select count(*)::integer
  into v_official_snapshot_count
  from public.match_set_versions msv
  where msv.official = true;

  select count(*)::integer
  into v_synced_round_count
  from public.fantagol_rounds fr
  join public.match_set_versions msv
    on msv.fantagol_round_id = fr.id
   and msv.version = fr.official_match_set_version
   and msv.official = true;

  select count(*)::integer
  into v_invalid_snapshot_count
  from public.match_set_versions msv
  where msv.official = true
    and (
      msv.version <> 1
      or cardinality(msv.match_ids_ordered) <> (
        select count(*)
        from public.fantagol_round_matches frm
        where frm.fantagol_round_id = msv.fantagol_round_id
          and frm.removed_at is null
      )
      or msv.match_ids_ordered is distinct from (
        select array_agg(frm.match_id order by frm.slot_number)
        from public.fantagol_round_matches frm
        where frm.fantagol_round_id = msv.fantagol_round_id
          and frm.removed_at is null
      )
    );

  if v_official_snapshot_count <> v_complete_round_count then
    raise exception using
      errcode = 'P0001',
      message = 'MATCH_SET_BACKFILL_OFFICIAL_COUNT_MISMATCH',
      detail = format(
        'complete_rounds=%s official_snapshots=%s',
        v_complete_round_count,
        v_official_snapshot_count
      );
  end if;

  if v_synced_round_count <> v_complete_round_count then
    raise exception using
      errcode = 'P0001',
      message = 'MATCH_SET_BACKFILL_SYNC_COUNT_MISMATCH',
      detail = format(
        'complete_rounds=%s synced_rounds=%s',
        v_complete_round_count,
        v_synced_round_count
      );
  end if;

  if v_invalid_snapshot_count <> 0 then
    raise exception using
      errcode = 'P0001',
      message = 'MATCH_SET_BACKFILL_VALIDATION_FAILED',
      detail = format('invalid_snapshots=%s', v_invalid_snapshot_count);
  end if;
end;
$block$;


-- ============================================================
-- 5. PRIVILEGES
-- ============================================================

revoke all on function public.ensure_initial_official_match_set_snapshot(uuid, text)
  from public;
revoke all on function public.ensure_initial_official_match_set_snapshot(uuid, text)
  from anon;
revoke all on function public.ensure_initial_official_match_set_snapshot(uuid, text)
  from authenticated;
grant execute on function public.ensure_initial_official_match_set_snapshot(uuid, text)
  to service_role;

revoke all on function public.create_initial_match_set_snapshot_after_round_match()
  from public;
revoke all on function public.create_initial_match_set_snapshot_after_round_match()
  from anon;
revoke all on function public.create_initial_match_set_snapshot_after_round_match()
  from authenticated;
grant execute on function public.create_initial_match_set_snapshot_after_round_match()
  to service_role;

commit;
