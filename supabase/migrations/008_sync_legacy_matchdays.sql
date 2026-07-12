begin;

insert into public.matchdays (
  id,
  season_id,
  number,
  start_date,
  end_date,
  created_at
)
select
  gen_random_uuid(),
  '5e6488f6-fbe7-4f0d-8669-9c749d2a4037'::uuid,
  pr.number,
  pr.starts_at::date,
  pr.ends_at::date,
  now()
from public.provider_rounds pr
where pr.edition_id = '00000000-0000-4000-8000-000000000201'::uuid
  and pr.number is not null
on conflict (season_id, number)
do update
set
  start_date = excluded.start_date,
  end_date = excluded.end_date;

commit;