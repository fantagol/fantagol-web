import { writeFile } from "node:fs/promises";
import { FootballDataAdapter } from "../lib/providers/football-data";

const LEGACY_SEASON_ID = "5e6488f6-fbe7-4f0d-8669-9c749d2a4037";
const EDITION_ID = "00000000-0000-4000-8000-000000000201";
const STAGE_ID = "00000000-0000-4000-8000-000000000301";
const OUTPUT = "supabase/migrations/009_import_serie_a_matches.sql";

function sqlText(value: string | null): string {
  if (value === null) return "null";
  return `'${value.replaceAll("'", "''")}'`;
}

async function main() {
  const adapter = new FootballDataAdapter();
  const matches = await adapter.getMatches("2019:2026");

  if (matches.length !== 380) {
    throw new Error(`Expected 380 matches, received ${matches.length}`);
  }

  const values = matches.map((match) => {
    const roundNumber = Number(match.providerRoundExternalId?.split(":").at(-1));
    if (!Number.isInteger(roundNumber)) {
      throw new Error(`Invalid round number for provider match ${match.externalId}`);
    }

    return `(
    ${sqlText(match.externalId)},
    ${roundNumber},
    ${sqlText(match.homeTeamExternalId)},
    ${sqlText(match.awayTeamExternalId)},
    ${sqlText(match.kickoffAt)},
    ${sqlText(match.status)},
    ${match.homeScore ?? "null"},
    ${match.awayScore ?? "null"},
    ${match.minute ?? "null"},
    ${sqlText(match.period)},
    ${sqlText(match.providerUpdatedAt)}
  )`;
  }).join(",\n");

  const sql = `begin;

create temporary table _serie_a_match_import (
  provider_match_id text primary key,
  matchday_number integer not null,
  home_provider_team_id text not null,
  away_provider_team_id text not null,
  kickoff_at timestamptz not null,
  status text not null,
  home_score integer,
  away_score integer,
  minute integer,
  period text,
  provider_updated_at timestamptz
) on commit drop;

insert into _serie_a_match_import values
${values};

create temporary table _resolved_serie_a_matches on commit drop as
select
  i.provider_match_id,
  i.matchday_number,
  home_map.internal_id as home_team_id,
  away_map.internal_id as away_team_id,
  md.id as matchday_id,
  pr.id as provider_round_id,
  i.kickoff_at,
  i.status,
  i.home_score,
  i.away_score,
  i.minute,
  i.period,
  i.provider_updated_at
from _serie_a_match_import i
join public.data_providers dp on dp.code = 'football_data'
join public.provider_entity_maps home_map
  on home_map.provider_id = dp.id
 and home_map.entity_type = 'team'
 and home_map.external_id = i.home_provider_team_id
 and home_map.active = true
join public.provider_entity_maps away_map
  on away_map.provider_id = dp.id
 and away_map.entity_type = 'team'
 and away_map.external_id = i.away_provider_team_id
 and away_map.active = true
join public.matchdays md
  on md.season_id = '${LEGACY_SEASON_ID}'::uuid
 and md.number = i.matchday_number
join public.provider_rounds pr
  on pr.provider_id = dp.id
 and pr.edition_id = '${EDITION_ID}'::uuid
 and pr.number = i.matchday_number;

-- First update matches already linked to the provider external ID.
-- This remains stable even when kickoff or matchday changes.
update public.matches m
set
  season_id = '${LEGACY_SEASON_ID}'::uuid,
  matchday_id = r.matchday_id,
  home_team_id = r.home_team_id,
  away_team_id = r.away_team_id,
  kickoff = r.kickoff_at,
  home_score = r.home_score,
  away_score = r.away_score,
  status = r.status,
  edition_id = '${EDITION_ID}'::uuid,
  stage_id = '${STAGE_ID}'::uuid,
  provider_round_id = r.provider_round_id,
  minute = r.minute,
  period = r.period,
  provider_updated_at = r.provider_updated_at,
  finalised_at = case
    when r.status in ('finished','awarded')
      then coalesce(m.finalised_at, r.provider_updated_at, now())
    else null
  end,
  active = true,
  updated_at = now(),
  version = m.version + 1
from _resolved_serie_a_matches r
join public.data_providers dp
  on dp.code = 'football_data'
join public.provider_entity_maps pem
  on pem.provider_id = dp.id
 and pem.entity_type = 'match'
 and pem.external_id = r.provider_match_id
 and pem.internal_id = m.id;

-- Then adopt legacy matches that do not yet have a provider mapping.
update public.matches m
set
  kickoff = r.kickoff_at,
  home_score = r.home_score,
  away_score = r.away_score,
  status = r.status,
  edition_id = '${EDITION_ID}'::uuid,
  stage_id = '${STAGE_ID}'::uuid,
  provider_round_id = r.provider_round_id,
  minute = r.minute,
  period = r.period,
  provider_updated_at = r.provider_updated_at,
  finalised_at = case
    when r.status in ('finished','awarded')
      then coalesce(m.finalised_at, r.provider_updated_at, now())
    else null
  end,
  active = true,
  updated_at = now(),
  version = m.version + 1
from _resolved_serie_a_matches r
where m.season_id = '${LEGACY_SEASON_ID}'::uuid
  and m.matchday_id = r.matchday_id
  and m.home_team_id = r.home_team_id
  and m.away_team_id = r.away_team_id
  and not exists (
    select 1
    from public.data_providers dp
    join public.provider_entity_maps pem
      on pem.provider_id = dp.id
     and pem.entity_type = 'match'
     and pem.internal_id = m.id
    where dp.code = 'football_data'
  );

insert into public.matches (
  id, season_id, matchday_id, home_team_id, away_team_id, kickoff,
  home_score, away_score, status, created_at, edition_id, stage_id,
  provider_round_id, venue_name, minute, period, provider_updated_at,
  finalised_at, active, updated_at, version
)
select
  gen_random_uuid(),
  '${LEGACY_SEASON_ID}'::uuid,
  r.matchday_id,
  r.home_team_id,
  r.away_team_id,
  r.kickoff_at,
  r.home_score,
  r.away_score,
  r.status,
  now(),
  '${EDITION_ID}'::uuid,
  '${STAGE_ID}'::uuid,
  r.provider_round_id,
  null,
  r.minute,
  r.period,
  r.provider_updated_at,
  case when r.status in ('finished','awarded') then coalesce(r.provider_updated_at, now()) else null end,
  true,
  now(),
  1
from _resolved_serie_a_matches r
where not exists (
  select 1
  from public.data_providers dp
  join public.provider_entity_maps pem
    on pem.provider_id = dp.id
   and pem.entity_type = 'match'
   and pem.external_id = r.provider_match_id
  where dp.code = 'football_data'
)
and not exists (
  select 1
  from public.matches m
  where m.season_id = '${LEGACY_SEASON_ID}'::uuid
    and m.matchday_id = r.matchday_id
    and m.home_team_id = r.home_team_id
    and m.away_team_id = r.away_team_id
);

insert into public.provider_entity_maps (
  provider_id, entity_type, internal_id, external_id,
  external_parent_id, metadata, active
)
select
  dp.id,
  'match',
  m.id,
  r.provider_match_id,
  '2019:2026',
  jsonb_build_object(
    'matchday_number', r.matchday_number,
    'kickoff_at', r.kickoff_at,
    'status', r.status,
    'provider_updated_at', r.provider_updated_at
  ),
  true
from _resolved_serie_a_matches r
join public.matches m
  on m.season_id = '${LEGACY_SEASON_ID}'::uuid
 and m.matchday_id = r.matchday_id
 and m.home_team_id = r.home_team_id
 and m.away_team_id = r.away_team_id
cross join public.data_providers dp
where dp.code = 'football_data'
on conflict (provider_id, entity_type, external_id)
do update set
  internal_id = excluded.internal_id,
  external_parent_id = excluded.external_parent_id,
  metadata = excluded.metadata,
  active = true;

do $$
declare
  match_count integer;
  mapping_count integer;
begin
  select count(*) into match_count
  from public.matches
  where edition_id = '${EDITION_ID}'::uuid and active = true;

  select count(*) into mapping_count
  from public.provider_entity_maps pem
  join public.data_providers dp on dp.id = pem.provider_id
  where dp.code = 'football_data'
    and pem.entity_type = 'match'
    and pem.active = true;

  if match_count <> 380 then
    raise exception 'SERIE_A_MATCH_COUNT_INVALID expected=380 actual=%', match_count;
  end if;

  if mapping_count <> 380 then
    raise exception 'SERIE_A_MATCH_MAPPING_COUNT_INVALID expected=380 actual=%', mapping_count;
  end if;
end;
$$;

commit;
`;

  await writeFile(OUTPUT, sql, "utf8");
  console.log(`Created ${OUTPUT}`);
  console.log(`Matches: ${matches.length}`);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
