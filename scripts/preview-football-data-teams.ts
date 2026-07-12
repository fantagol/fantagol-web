import { FootballDataAdapter } from "../lib/providers/football-data";

async function main() {
  const adapter = new FootballDataAdapter();
  const teams = await adapter.getTeams("2019:2026");

  console.table(
  teams.map((team, index) => ({
    slot: index + 1,
    externalId: team.externalId,
    name: team.name,
    shortName: team.shortName,
    code: team.code,
    countryCode: team.countryCode,
    crestUrl: team.crestUrl,
  })),
);

  console.log(`\nTotale squadre: ${teams.length}`);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});