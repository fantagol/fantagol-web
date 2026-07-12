-- ============================================================
-- FANTAGOL
-- MIGRATION 002
-- SEED SERIE A 2026/27
--
-- Purpose:
--   Create the initial Competition Edition and Stage
--   for the Serie A 2026/27 product launch.
--
-- Properties:
--   - idempotent
--   - non-destructive
--   - provider-independent
--   - legacy-compatible
-- ============================================================

begin;

-- ------------------------------------------------------------
-- 1. VERIFY REQUIRED PARENT ENTITIES
-- ------------------------------------------------------------

do $$
begin
  if not exists (
    select 1
    from public.sports
    where code = 'football'
      and active = true
  ) then
    raise exception
      using
        errcode = 'P0001',
        message = 'FOUNDATION_SPORT_FOOTBALL_MISSING';
  end if;

  if not exists (
    select 1
    from public.competitions
    where code = 'serie_a'
      and enabled = true
  ) then
    raise exception
      using
        errcode = 'P0001',
        message = 'FOUNDATION_COMPETITION_SERIE_A_MISSING';
  end if;
end;
$$;

-- ------------------------------------------------------------
-- 2. CREATE COMPETITION EDITION
--
-- Dates are a technical season envelope.
-- The provider synchronization may later refine calendar dates
-- without changing the identity of the Edition.
-- ------------------------------------------------------------

insert into public.competition_editions (
  id,
  competition_id,
  label,
  provider_label,
  year_start,
  year_end,
  starts_at,
  ends_at,
  status,
  active
)
select
  '00000000-0000-4000-8000-000000000201'::uuid,
  c.id,
  '2026/27',
  'Serie A 2026/27',
  2026,
  2027,
  '2026-07-01 00:00:00+00'::timestamptz,
  '2027-06-30 23:59:59+00'::timestamptz,
  'scheduled',
  true
from public.competitions c
where c.code = 'serie_a'

on conflict (competition_id, label)
do update
set
  provider_label = excluded.provider_label,
  year_start = excluded.year_start,
  year_end = excluded.year_end,
  starts_at = excluded.starts_at,
  ends_at = excluded.ends_at,
  active = true;

-- ------------------------------------------------------------
-- 3. CREATE REGULAR-SEASON STAGE
-- ------------------------------------------------------------

insert into public.competition_stages (
  id,
  edition_id,
  code,
  name_key,
  stage_type,
  sequence,
  starts_at,
  ends_at,
  active
)
select
  '00000000-0000-4000-8000-000000000301'::uuid,
  ce.id,
  'regular_season',
  'competition_stage.regular_season',
  'regular_season',
  1,
  null,
  null,
  true
from public.competition_editions ce
join public.competitions c
  on c.id = ce.competition_id
where c.code = 'serie_a'
  and ce.label = '2026/27'

on conflict (edition_id, code)
do update
set
  name_key = excluded.name_key,
  stage_type = excluded.stage_type,
  sequence = excluded.sequence,
  active = true;

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
  'competition_edition_seeded',
  'competition_edition',
  ce.id,
  null,
  jsonb_build_object(
    'competition_code', c.code,
    'edition_label', ce.label,
    'year_start', ce.year_start,
    'year_end', ce.year_end,
    'status', ce.status,
    'stage_code', cs.code,
    'stage_type', cs.stage_type
  ),
  'Initial Serie A 2026/27 Competition Engine seed',
  '00000000-0000-4000-8000-000000000002'::uuid
from public.competition_editions ce
join public.competitions c
  on c.id = ce.competition_id
join public.competition_stages cs
  on cs.edition_id = ce.id
where c.code = 'serie_a'
  and ce.label = '2026/27'
  and cs.code = 'regular_season'
  and not exists (
    select 1
    from public.competition_audit_log cal
    where cal.action = 'competition_edition_seeded'
      and cal.aggregate_type = 'competition_edition'
      and cal.aggregate_id = ce.id
  );

commit;