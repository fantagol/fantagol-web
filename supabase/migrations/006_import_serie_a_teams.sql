-- ============================================================
-- FANTAGOL
-- MIGRATION 006
-- IMPORT SERIE A 2026/27 TEAMS
-- ============================================================

begin;

do $$
declare
  expected_team_count integer := 20;
  actual_team_count integer;
begin
  if not exists (
    select 1 from public.data_providers
    where code = 'football_data' and active = true
  ) then
    raise exception 'FOOTBALL_DATA_PROVIDER_NOT_ACTIVE';
  end if;

  if not exists (
    select 1 from public.competition_editions
    where id = '00000000-0000-4000-8000-000000000201'::uuid
      and label = '2026/27' and active = true
  ) then
    raise exception 'SERIE_A_EDITION_2026_27_NOT_FOUND';
  end if;

  select count(*) into actual_team_count
  from public.teams
  where id in (
    '61d2b783-fa32-407c-857e-48956b8fe621'::uuid,
    '794de5c4-36a2-4dc2-9ebf-c50b3246be49'::uuid,
    '7d6bac56-59ac-436a-bdcd-68ce3eea1a0b'::uuid,
    'f473fbb4-0f55-434c-8465-d336f30fc6ed'::uuid,
    'cad662d7-ea6c-4825-9990-a3c7bc715169'::uuid,
    '0c3189a3-bec4-4818-a2b3-67fe0c5e5328'::uuid,
    'cf5ad783-7bf8-40a6-9976-0aaf650298d2'::uuid,
    '30fe6d53-62cf-41a9-a0be-6cec687cb2c1'::uuid,
    'e0d243bd-98fb-4149-a4d5-223a1a8efc88'::uuid,
    '552bc8cb-304d-46ed-8495-10c9f9e3de1d'::uuid,
    '0642f870-07d9-44a4-8819-a0bc3e425a7d'::uuid,
    'e68e6891-e54c-4d9e-9bb8-4e4cd90e1b0c'::uuid,
    'f852b383-d8dd-4d30-a60a-86a0952173cd'::uuid,
    'd0cdc8bf-d5a6-403e-8bbc-e4b28e5998f6'::uuid,
    '119eb2e8-01d3-4c3c-a025-7572dbd5e42f'::uuid,
    '9e7f92a1-fa2d-479c-a68d-00b488442e86'::uuid,
    '50b33143-69fa-443f-b7c9-8e97d911b2bd'::uuid,
    '34c1944f-1a01-444c-9a43-2481b6bbb745'::uuid,
    '2ee56193-d10d-4169-8b57-4d49c7b82490'::uuid,
    '2161b8b1-7dbc-4903-93ee-04a51b45bca9'::uuid
  );

  if actual_team_count <> expected_team_count then
    raise exception 'SERIE_A_TEAM_PRECONDITION_FAILED expected=% actual=%', expected_team_count, actual_team_count;
  end if;
end;
$$;

create temporary table _serie_a_team_import (
  internal_id uuid primary key,
  provider_external_id text not null unique,
  canonical_name text not null,
  canonical_short_name text not null,
  canonical_code text not null,
  country_code text not null,
  crest_reference text not null
) on commit drop;

insert into _serie_a_team_import values
  ('e68e6891-e54c-4d9e-9bb8-4e4cd90e1b0c', '98',   'AC Milan',                 'Milan',      'MIL', 'ITA', 'https://crests.football-data.org/98.png'),
  ('cad662d7-ea6c-4825-9990-a3c7bc715169', '99',   'ACF Fiorentina',           'Fiorentina', 'FIO', 'ITA', 'https://crests.football-data.org/99.png'),
  ('9e7f92a1-fa2d-479c-a68d-00b488442e86', '100',  'AS Roma',                  'Roma',       'ROM', 'ITA', 'https://crests.football-data.org/100.png'),
  ('61d2b783-fa32-407c-857e-48956b8fe621', '102',  'Atalanta BC',              'Atalanta',   'ATA', 'ITA', 'https://crests.football-data.org/102.png'),
  ('794de5c4-36a2-4dc2-9ebf-c50b3246be49', '103',  'Bologna FC 1909',          'Bologna',    'BOL', 'ITA', 'https://crests.football-data.org/103.png'),
  ('7d6bac56-59ac-436a-bdcd-68ce3eea1a0b', '104',  'Cagliari Calcio',          'Cagliari',   'CAG', 'ITA', 'https://crests.football-data.org/104.png'),
  ('cf5ad783-7bf8-40a6-9976-0aaf650298d2', '107',  'Genoa CFC',                'Genoa',      'GEN', 'ITA', 'https://crests.football-data.org/107.png'),
  ('30fe6d53-62cf-41a9-a0be-6cec687cb2c1', '108',  'FC Internazionale Milano', 'Inter',      'INT', 'ITA', 'https://crests.football-data.org/108.png'),
  ('e0d243bd-98fb-4149-a4d5-223a1a8efc88', '109',  'Juventus FC',              'Juventus',   'JUV', 'ITA', 'https://crests.football-data.org/109.png'),
  ('552bc8cb-304d-46ed-8495-10c9f9e3de1d', '110',  'SS Lazio',                 'Lazio',      'LAZ', 'ITA', 'https://crests.football-data.org/110.png'),
  ('119eb2e8-01d3-4c3c-a025-7572dbd5e42f', '112',  'Parma Calcio 1913',        'Parma',      'PAR', 'ITA', 'https://crests.football-data.org/112.png'),
  ('d0cdc8bf-d5a6-403e-8bbc-e4b28e5998f6', '113',  'SSC Napoli',               'Napoli',     'NAP', 'ITA', 'https://crests.football-data.org/113.png'),
  ('2ee56193-d10d-4169-8b57-4d49c7b82490', '115',  'Udinese Calcio',           'Udinese',    'UDI', 'ITA', 'https://crests.football-data.org/115.png'),
  ('2161b8b1-7dbc-4903-93ee-04a51b45bca9', '454',  'Venezia FC',               'Venezia',    'VEN', 'ITA', 'https://crests.football-data.org/454.png'),
  ('0c3189a3-bec4-4818-a2b3-67fe0c5e5328', '470',  'Frosinone Calcio',         'Frosinone',  'FRO', 'ITA', 'https://crests.football-data.org/470.png'),
  ('50b33143-69fa-443f-b7c9-8e97d911b2bd', '471',  'US Sassuolo Calcio',       'Sassuolo',   'SAS', 'ITA', 'https://crests.football-data.org/471.png'),
  ('34c1944f-1a01-444c-9a43-2481b6bbb745', '586',  'Torino FC',                'Torino',     'TOR', 'ITA', 'https://crests.football-data.org/586.png'),
  ('0642f870-07d9-44a4-8819-a0bc3e425a7d', '5890', 'US Lecce',                 'Lecce',      'USL', 'ITA', 'https://crests.football-data.org/5890.png'),
  ('f852b383-d8dd-4d30-a60a-86a0952173cd', '5911', 'AC Monza',                 'Monza',      'MON', 'ITA', 'https://crests.football-data.org/5911.png'),
  ('f473fbb4-0f55-434c-8465-d336f30fc6ed', '7397', 'Como 1907',                'Como',       'COM', 'ITA', 'https://crests.football-data.org/7397.png');

update public.teams t
set
  name = i.canonical_name,
  short_name = i.canonical_short_name,
  code = i.canonical_code,
  country_code = i.country_code,
  crest_reference = i.crest_reference,
  team_type = 'club',
  active = true
from _serie_a_team_import i
where t.id = i.internal_id;

insert into public.provider_entity_maps (
  provider_id, entity_type, internal_id, external_id,
  external_parent_id, metadata, active
)
select
  dp.id,
  'team',
  i.internal_id,
  i.provider_external_id,
  '2019:2026',
  jsonb_build_object(
    'name', i.canonical_name,
    'short_name', i.canonical_short_name,
    'code', i.canonical_code,
    'country_code', i.country_code,
    'crest_reference', i.crest_reference
  ),
  true
from _serie_a_team_import i
cross join public.data_providers dp
where dp.code = 'football_data'
on conflict (provider_id, entity_type, internal_id)
do update set
  external_id = excluded.external_id,
  external_parent_id = excluded.external_parent_id,
  metadata = excluded.metadata,
  active = true;

insert into public.competition_teams (
  edition_id, team_id, group_code, seed, active
)
select
  '00000000-0000-4000-8000-000000000201'::uuid,
  i.internal_id,
  null,
  null,
  true
from _serie_a_team_import i
on conflict (edition_id, team_id)
do update set
  active = true,
  left_at = null;

insert into public.competition_audit_log (
  actor_id, action, aggregate_type, aggregate_id,
  before_json, after_json, reason, correlation_id
)
select
  null,
  'serie_a_teams_imported',
  'competition_edition',
  '00000000-0000-4000-8000-000000000201'::uuid,
  null,
  jsonb_build_object(
    'provider_code', 'football_data',
    'competition_external_id', '2019',
    'edition_external_id', '2019:2026',
    'team_count', 20
  ),
  'Imported and mapped the 20 Serie A 2026/27 teams',
  '00000000-0000-4000-8000-000000000006'::uuid
where not exists (
  select 1 from public.competition_audit_log cal
  where cal.action = 'serie_a_teams_imported'
    and cal.aggregate_type = 'competition_edition'
    and cal.aggregate_id = '00000000-0000-4000-8000-000000000201'::uuid
);

commit;
