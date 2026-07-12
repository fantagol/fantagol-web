-- ============================================================
-- FANTAGOL
-- MIGRATION 005
-- FOOTBALL-DATA.ORG SERIE A ENTITY MAPS
--
-- Collega le entità interne FantaGol alle identità normalizzate
-- restituite dal Football Data Adapter.
-- ============================================================

begin;

do $$
begin
  if not exists (
    select 1
    from public.data_providers
    where code = 'football_data'
      and active = true
  ) then
    raise exception 'FOOTBALL_DATA_PROVIDER_NOT_ACTIVE';
  end if;

  if not exists (
    select 1
    from public.competitions
    where id = '00000000-0000-4000-8000-000000000101'::uuid
      and code = 'serie_a'
  ) then
    raise exception 'SERIE_A_COMPETITION_NOT_FOUND';
  end if;

  if not exists (
    select 1
    from public.competition_editions
    where id = '00000000-0000-4000-8000-000000000201'::uuid
      and label = '2026/27'
  ) then
    raise exception 'SERIE_A_EDITION_2026_27_NOT_FOUND';
  end if;

  if not exists (
    select 1
    from public.competition_stages
    where id = '00000000-0000-4000-8000-000000000301'::uuid
      and code = 'regular_season'
  ) then
    raise exception 'SERIE_A_REGULAR_SEASON_NOT_FOUND';
  end if;
end;
$$;

-- Competition: Serie A
insert into public.provider_entity_maps (
  provider_id,
  entity_type,
  internal_id,
  external_id,
  external_parent_id,
  metadata,
  active
)
select
  dp.id,
  'competition',
  '00000000-0000-4000-8000-000000000101'::uuid,
  '2019',
  null,
  jsonb_build_object(
    'provider_code', 'SA',
    'provider_name', 'Serie A',
    'provider_type', 'LEAGUE'
  ),
  true
from public.data_providers dp
where dp.code = 'football_data'
on conflict (provider_id, entity_type, internal_id)
do update set
  external_id = excluded.external_id,
  external_parent_id = excluded.external_parent_id,
  metadata = excluded.metadata,
  active = true;

-- Edition: Serie A 2026/27
insert into public.provider_entity_maps (
  provider_id,
  entity_type,
  internal_id,
  external_id,
  external_parent_id,
  metadata,
  active
)
select
  dp.id,
  'edition',
  '00000000-0000-4000-8000-000000000201'::uuid,
  '2019:2026',
  '2019',
  jsonb_build_object(
    'provider_season_id', 2494,
    'season_start_year', 2026,
    'start_date', '2026-08-23',
    'end_date', '2027-05-30'
  ),
  true
from public.data_providers dp
where dp.code = 'football_data'
on conflict (provider_id, entity_type, internal_id)
do update set
  external_id = excluded.external_id,
  external_parent_id = excluded.external_parent_id,
  metadata = excluded.metadata,
  active = true;

-- Stage: Regular Season
insert into public.provider_entity_maps (
  provider_id,
  entity_type,
  internal_id,
  external_id,
  external_parent_id,
  metadata,
  active
)
select
  dp.id,
  'stage',
  '00000000-0000-4000-8000-000000000301'::uuid,
  '2019:2026:REGULAR_SEASON',
  '2019:2026',
  jsonb_build_object(
    'provider_stage', 'REGULAR_SEASON'
  ),
  true
from public.data_providers dp
where dp.code = 'football_data'
on conflict (provider_id, entity_type, internal_id)
do update set
  external_id = excluded.external_id,
  external_parent_id = excluded.external_parent_id,
  metadata = excluded.metadata,
  active = true;

commit;