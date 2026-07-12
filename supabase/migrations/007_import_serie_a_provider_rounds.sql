-- ============================================================
-- FANTAGOL
-- MIGRATION 007
-- IMPORT SERIE A 2026/27 PROVIDER ROUNDS
--
-- Generated from football-data.org via Provider Adapter.
-- Idempotent and non-destructive.
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
end;
$$;

insert into public.provider_rounds (
  id,
  provider_id,
  edition_id,
  stage_id,
  external_id,
  name,
  number,
  starts_at,
  ends_at,
  source_payload_hash,
  synced_at,
  created_at,
  updated_at,
  version
)
select
  v.id,
  dp.id,
  '00000000-0000-4000-8000-000000000201'::uuid,
  '00000000-0000-4000-8000-000000000301'::uuid,
  v.external_id,
  v.name,
  v.number,
  v.starts_at::timestamptz,
  v.ends_at::timestamptz,
  null,
  now(),
  now(),
  now(),
  1
from (
  values
(
    gen_random_uuid(),
    '2019:2026:matchday:1',
    'Matchday 1',
    1,
    '2026-08-23T16:30:00.000Z',
    '2026-08-23T16:30:00.000Z'
  ),
(
    gen_random_uuid(),
    '2019:2026:matchday:2',
    'Matchday 2',
    2,
    '2026-08-30T16:30:00.000Z',
    '2026-08-30T16:30:00.000Z'
  ),
(
    gen_random_uuid(),
    '2019:2026:matchday:3',
    'Matchday 3',
    3,
    '2026-09-06T16:30:00.000Z',
    '2026-09-06T16:30:00.000Z'
  ),
(
    gen_random_uuid(),
    '2019:2026:matchday:4',
    'Matchday 4',
    4,
    '2026-09-13T16:30:00.000Z',
    '2026-09-13T16:30:00.000Z'
  ),
(
    gen_random_uuid(),
    '2019:2026:matchday:5',
    'Matchday 5',
    5,
    '2026-09-20T16:30:00.000Z',
    '2026-09-20T16:30:00.000Z'
  ),
(
    gen_random_uuid(),
    '2019:2026:matchday:6',
    'Matchday 6',
    6,
    '2026-10-11T16:30:00.000Z',
    '2026-10-11T16:30:00.000Z'
  ),
(
    gen_random_uuid(),
    '2019:2026:matchday:7',
    'Matchday 7',
    7,
    '2026-10-18T16:30:00.000Z',
    '2026-10-18T16:30:00.000Z'
  ),
(
    gen_random_uuid(),
    '2019:2026:matchday:8',
    'Matchday 8',
    8,
    '2026-10-25T17:30:00.000Z',
    '2026-10-25T17:30:00.000Z'
  ),
(
    gen_random_uuid(),
    '2019:2026:matchday:9',
    'Matchday 9',
    9,
    '2026-10-28T17:30:00.000Z',
    '2026-10-28T17:30:00.000Z'
  ),
(
    gen_random_uuid(),
    '2019:2026:matchday:10',
    'Matchday 10',
    10,
    '2026-11-01T17:30:00.000Z',
    '2026-11-01T17:30:00.000Z'
  ),
(
    gen_random_uuid(),
    '2019:2026:matchday:11',
    'Matchday 11',
    11,
    '2026-11-08T17:30:00.000Z',
    '2026-11-08T17:30:00.000Z'
  ),
(
    gen_random_uuid(),
    '2019:2026:matchday:12',
    'Matchday 12',
    12,
    '2026-11-22T17:30:00.000Z',
    '2026-11-22T17:30:00.000Z'
  ),
(
    gen_random_uuid(),
    '2019:2026:matchday:13',
    'Matchday 13',
    13,
    '2026-11-29T17:30:00.000Z',
    '2026-11-29T17:30:00.000Z'
  ),
(
    gen_random_uuid(),
    '2019:2026:matchday:14',
    'Matchday 14',
    14,
    '2026-12-06T17:30:00.000Z',
    '2026-12-06T17:30:00.000Z'
  ),
(
    gen_random_uuid(),
    '2019:2026:matchday:15',
    'Matchday 15',
    15,
    '2026-12-13T17:30:00.000Z',
    '2026-12-13T17:30:00.000Z'
  ),
(
    gen_random_uuid(),
    '2019:2026:matchday:16',
    'Matchday 16',
    16,
    '2026-12-20T17:30:00.000Z',
    '2026-12-20T17:30:00.000Z'
  ),
(
    gen_random_uuid(),
    '2019:2026:matchday:17',
    'Matchday 17',
    17,
    '2027-01-03T12:00:00.000Z',
    '2027-01-03T12:00:00.000Z'
  ),
(
    gen_random_uuid(),
    '2019:2026:matchday:18',
    'Matchday 18',
    18,
    '2027-01-06T12:00:00.000Z',
    '2027-01-06T12:00:00.000Z'
  ),
(
    gen_random_uuid(),
    '2019:2026:matchday:19',
    'Matchday 19',
    19,
    '2027-01-10T12:00:00.000Z',
    '2027-01-10T12:00:00.000Z'
  ),
(
    gen_random_uuid(),
    '2019:2026:matchday:20',
    'Matchday 20',
    20,
    '2027-01-17T12:00:00.000Z',
    '2027-01-17T12:00:00.000Z'
  ),
(
    gen_random_uuid(),
    '2019:2026:matchday:21',
    'Matchday 21',
    21,
    '2027-01-24T12:00:00.000Z',
    '2027-01-24T12:00:00.000Z'
  ),
(
    gen_random_uuid(),
    '2019:2026:matchday:22',
    'Matchday 22',
    22,
    '2027-01-31T12:00:00.000Z',
    '2027-01-31T12:00:00.000Z'
  ),
(
    gen_random_uuid(),
    '2019:2026:matchday:23',
    'Matchday 23',
    23,
    '2027-02-07T12:00:00.000Z',
    '2027-02-07T12:00:00.000Z'
  ),
(
    gen_random_uuid(),
    '2019:2026:matchday:24',
    'Matchday 24',
    24,
    '2027-02-14T12:00:00.000Z',
    '2027-02-14T12:00:00.000Z'
  ),
(
    gen_random_uuid(),
    '2019:2026:matchday:25',
    'Matchday 25',
    25,
    '2027-02-21T12:00:00.000Z',
    '2027-02-21T12:00:00.000Z'
  ),
(
    gen_random_uuid(),
    '2019:2026:matchday:26',
    'Matchday 26',
    26,
    '2027-02-28T12:00:00.000Z',
    '2027-02-28T12:00:00.000Z'
  ),
(
    gen_random_uuid(),
    '2019:2026:matchday:27',
    'Matchday 27',
    27,
    '2027-03-07T12:00:00.000Z',
    '2027-03-07T12:00:00.000Z'
  ),
(
    gen_random_uuid(),
    '2019:2026:matchday:28',
    'Matchday 28',
    28,
    '2027-03-14T12:00:00.000Z',
    '2027-03-14T12:00:00.000Z'
  ),
(
    gen_random_uuid(),
    '2019:2026:matchday:29',
    'Matchday 29',
    29,
    '2027-03-21T12:00:00.000Z',
    '2027-03-21T12:00:00.000Z'
  ),
(
    gen_random_uuid(),
    '2019:2026:matchday:30',
    'Matchday 30',
    30,
    '2027-04-04T12:00:00.000Z',
    '2027-04-04T12:00:00.000Z'
  ),
(
    gen_random_uuid(),
    '2019:2026:matchday:31',
    'Matchday 31',
    31,
    '2027-04-11T12:00:00.000Z',
    '2027-04-11T12:00:00.000Z'
  ),
(
    gen_random_uuid(),
    '2019:2026:matchday:32',
    'Matchday 32',
    32,
    '2027-04-18T12:00:00.000Z',
    '2027-04-18T12:00:00.000Z'
  ),
(
    gen_random_uuid(),
    '2019:2026:matchday:33',
    'Matchday 33',
    33,
    '2027-04-25T12:00:00.000Z',
    '2027-04-25T12:00:00.000Z'
  ),
(
    gen_random_uuid(),
    '2019:2026:matchday:34',
    'Matchday 34',
    34,
    '2027-05-02T12:00:00.000Z',
    '2027-05-02T12:00:00.000Z'
  ),
(
    gen_random_uuid(),
    '2019:2026:matchday:35',
    'Matchday 35',
    35,
    '2027-05-09T12:00:00.000Z',
    '2027-05-09T12:00:00.000Z'
  ),
(
    gen_random_uuid(),
    '2019:2026:matchday:36',
    'Matchday 36',
    36,
    '2027-05-16T12:00:00.000Z',
    '2027-05-16T12:00:00.000Z'
  ),
(
    gen_random_uuid(),
    '2019:2026:matchday:37',
    'Matchday 37',
    37,
    '2027-05-23T12:00:00.000Z',
    '2027-05-23T12:00:00.000Z'
  ),
(
    gen_random_uuid(),
    '2019:2026:matchday:38',
    'Matchday 38',
    38,
    '2027-05-30T12:00:00.000Z',
    '2027-05-30T12:00:00.000Z'
  )
) as v(
  id,
  external_id,
  name,
  number,
  starts_at,
  ends_at
)
cross join public.data_providers dp
where dp.code = 'football_data'
on conflict (provider_id, edition_id, external_id)
do update
set
  stage_id = excluded.stage_id,
  name = excluded.name,
  number = excluded.number,
  starts_at = excluded.starts_at,
  ends_at = excluded.ends_at,
  synced_at = now(),
  updated_at = now(),
  version = public.provider_rounds.version + 1;

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
  'serie_a_provider_rounds_imported',
  'competition_edition',
  '00000000-0000-4000-8000-000000000201'::uuid,
  null,
  jsonb_build_object(
    'provider_code', 'football_data',
    'edition_external_id', '2019:2026',
    'provider_round_count', 38
  ),
  'Imported 38 Serie A 2026/27 provider rounds',
  '00000000-0000-4000-8000-000000000007'::uuid
where not exists (
  select 1
  from public.competition_audit_log cal
  where cal.action = 'serie_a_provider_rounds_imported'
    and cal.aggregate_id = '00000000-0000-4000-8000-000000000201'::uuid
);

commit;
