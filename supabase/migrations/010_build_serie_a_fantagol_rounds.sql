-- ============================================================
-- FANTAGOL
-- MIGRATION 010
-- BUILD SERIE A 2026/27 FANTAGOL ROUNDS
--
-- Creates:
--   - 38 fantagol_rounds
--   - 380 fantagol_round_matches
--
-- Source:
--   - provider_rounds
--   - matches
--
-- Properties:
--   - idempotent
--   - non-destructive
--   - official matchweek policy
-- ============================================================

begin;

do $$
begin
  if (
    select count(*)
    from public.provider_rounds
    where edition_id = '00000000-0000-4000-8000-000000000201'::uuid
  ) <> 38 then
    raise exception 'SERIE_A_PROVIDER_ROUNDS_INCOMPLETE';
  end if;

  if (
    select count(*)
    from public.matches
    where edition_id = '00000000-0000-4000-8000-000000000201'::uuid
      and active = true
  ) <> 380 then
    raise exception 'SERIE_A_MATCHES_INCOMPLETE';
  end if;
end;
$$;

-- ------------------------------------------------------------
-- 1. CREATE / UPDATE 38 FANTAGOL ROUNDS
-- ------------------------------------------------------------

with round_source as (
  select
    pr.number as sequence,
    pr.starts_at,
    pr.ends_at,
    lag(pr.ends_at) over (order by pr.number) as previous_round_ends_at
  from public.provider_rounds pr
  where pr.edition_id = '00000000-0000-4000-8000-000000000201'::uuid
)
insert into public.fantagol_rounds (
  id,
  edition_id,
  stage_id,
  name,
  sequence,
  target_match_count,
  minimum_match_count,
  maximum_match_count,
  selection_policy,
  opens_at,
  lock_at,
  starts_at,
  ends_at,
  status,
  active,
  official_match_set_version,
  created_at,
  updated_at,
  version
)
select
  gen_random_uuid(),
  '00000000-0000-4000-8000-000000000201'::uuid,
  '00000000-0000-4000-8000-000000000301'::uuid,
  'Giornata ' || rs.sequence,
  rs.sequence,
  10,
  10,
  10,
  'official_matchweek',
  case
    when rs.previous_round_ends_at is not null
      and rs.previous_round_ends_at < rs.starts_at
      then rs.previous_round_ends_at
    else rs.starts_at - interval '7 days'
  end,
  rs.starts_at,
  rs.starts_at,
  rs.ends_at,
  case
    when now() < (
      case
        when rs.previous_round_ends_at is not null
          and rs.previous_round_ends_at < rs.starts_at
          then rs.previous_round_ends_at
        else rs.starts_at - interval '7 days'
      end
    ) then 'scheduled'
    when now() < rs.starts_at then 'predictions_open'
    when now() >= rs.starts_at
      and (rs.ends_at is null or now() <= rs.ends_at) then 'live'
    else 'final_calculable'
  end,
  true,
  null,
  now(),
  now(),
  1
from round_source rs
on conflict (edition_id, sequence)
do update
set
  stage_id = excluded.stage_id,
  name = excluded.name,
  target_match_count = excluded.target_match_count,
  minimum_match_count = excluded.minimum_match_count,
  maximum_match_count = excluded.maximum_match_count,
  selection_policy = excluded.selection_policy,
  opens_at = excluded.opens_at,
  lock_at = excluded.lock_at,
  starts_at = excluded.starts_at,
  ends_at = excluded.ends_at,
  active = true,
  updated_at = now(),
  version = public.fantagol_rounds.version + 1;

-- ------------------------------------------------------------
-- 2. CREATE / UPDATE 380 ROUND MATCH LINKS
-- ------------------------------------------------------------

with ordered_matches as (
  select
    fr.id as fantagol_round_id,
    m.id as match_id,
    pr.id as source_provider_round_id,
    row_number() over (
      partition by fr.id
      order by m.kickoff, m.id
    )::integer as slot_number
  from public.fantagol_rounds fr
  join public.provider_rounds pr
    on pr.edition_id = fr.edition_id
   and pr.number = fr.sequence
  join public.matches m
    on m.provider_round_id = pr.id
   and m.active = true
  where fr.edition_id = '00000000-0000-4000-8000-000000000201'::uuid
)
insert into public.fantagol_round_matches (
  id,
  fantagol_round_id,
  match_id,
  slot_number,
  selection_reason,
  source_provider_round_id,
  required,
  included_at,
  removed_at,
  version
)
select
  gen_random_uuid(),
  om.fantagol_round_id,
  om.match_id,
  om.slot_number,
  'official_matchweek',
  om.source_provider_round_id,
  true,
  now(),
  null,
  1
from ordered_matches om
on conflict (fantagol_round_id, match_id)
do update
set
  slot_number = excluded.slot_number,
  selection_reason = excluded.selection_reason,
  source_provider_round_id = excluded.source_provider_round_id,
  required = true,
  removed_at = null,
  version = public.fantagol_round_matches.version + 1;

-- ------------------------------------------------------------
-- 3. FINAL CONSISTENCY CHECKS
-- ------------------------------------------------------------

do $$
declare
  round_count integer;
  round_match_count integer;
  invalid_round_count integer;
begin
  select count(*)
  into round_count
  from public.fantagol_rounds
  where edition_id = '00000000-0000-4000-8000-000000000201'::uuid
    and active = true;

  select count(*)
  into round_match_count
  from public.fantagol_round_matches frm
  join public.fantagol_rounds fr
    on fr.id = frm.fantagol_round_id
  where fr.edition_id = '00000000-0000-4000-8000-000000000201'::uuid
    and frm.removed_at is null;

  select count(*)
  into invalid_round_count
  from (
    select
      fr.id,
      count(frm.id) as match_count,
      min(frm.slot_number) as first_slot,
      max(frm.slot_number) as last_slot
    from public.fantagol_rounds fr
    left join public.fantagol_round_matches frm
      on frm.fantagol_round_id = fr.id
     and frm.removed_at is null
    where fr.edition_id = '00000000-0000-4000-8000-000000000201'::uuid
    group by fr.id
    having count(frm.id) <> 10
       or min(frm.slot_number) <> 1
       or max(frm.slot_number) <> 10
  ) invalid_rounds;

  if round_count <> 38 then
    raise exception
      'FANTAGOL_ROUND_COUNT_INVALID expected=38 actual=%',
      round_count;
  end if;

  if round_match_count <> 380 then
    raise exception
      'FANTAGOL_ROUND_MATCH_COUNT_INVALID expected=380 actual=%',
      round_match_count;
  end if;

  if invalid_round_count <> 0 then
    raise exception
      'FANTAGOL_ROUND_STRUCTURE_INVALID rounds=%',
      invalid_round_count;
  end if;
end;
$$;

-- ------------------------------------------------------------
-- 4. AUDIT
-- ------------------------------------------------------------

insert into public.competition_audit_log (
  actor_id,
  action,
  aggregate_type,
  aggregate_id,
  before_json,
  after_json,
  reason,
  correlation_id
)
select
  null,
  'serie_a_fantagol_rounds_built',
  'competition_edition',
  '00000000-0000-4000-8000-000000000201'::uuid,
  null,
  jsonb_build_object(
    'round_count', 38,
    'round_match_count', 380,
    'selection_policy', 'official_matchweek',
    'target_match_count', 10
  ),
  'Built the official Serie A 2026/27 FantaGol rounds',
  '00000000-0000-4000-8000-000000000010'::uuid
where not exists (
  select 1
  from public.competition_audit_log cal
  where cal.action = 'serie_a_fantagol_rounds_built'
    and cal.aggregate_id =
      '00000000-0000-4000-8000-000000000201'::uuid
);

commit;
