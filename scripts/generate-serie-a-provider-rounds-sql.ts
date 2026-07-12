import { writeFile } from "node:fs/promises";
import { FootballDataAdapter } from "../lib/providers/football-data";

const EDITION_ID = "00000000-0000-4000-8000-000000000201";
const STAGE_ID = "00000000-0000-4000-8000-000000000301";
const OUTPUT =
  "supabase/migrations/007_import_serie_a_provider_rounds.sql";

function sqlText(value: string | null): string {
  if (value === null) return "null";
  return `'${value.replaceAll("'", "''")}'`;
}

async function main() {
  const adapter = new FootballDataAdapter();
  const rounds = await adapter.getRounds("2019:2026");

  if (rounds.length !== 38) {
    throw new Error(
      `Expected 38 provider rounds, received ${rounds.length}`,
    );
  }

  const values = rounds
    .map(
      (round) => `(
    gen_random_uuid(),
    ${sqlText(round.externalId)},
    ${sqlText(round.name)},
    ${round.number ?? "null"},
    ${sqlText(round.startsAt)},
    ${sqlText(round.endsAt)}
  )`,
    )
    .join(",\n");

  const sql = `-- ============================================================
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
  '${EDITION_ID}'::uuid,
  '${STAGE_ID}'::uuid,
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
${values}
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
  '${EDITION_ID}'::uuid,
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
    and cal.aggregate_id = '${EDITION_ID}'::uuid
);

commit;
`;

  await writeFile(OUTPUT, sql, "utf8");
  console.log(`Created ${OUTPUT}`);
  console.log(`Provider rounds: ${rounds.length}`);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
