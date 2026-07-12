import { FootballDataAdapter } from "../lib/providers/football-data";

async function main() {
  const adapter = new FootballDataAdapter();

  const competition = await adapter.getCompetition("2019");
  const edition = await adapter.getEdition("2019", 2026);
  const teams = await adapter.getTeams("2019:2026");
  const rounds = await adapter.getRounds("2019:2026");
  const matches = await adapter.getMatches("2019:2026");

  console.log({
    competition: {
      externalId: competition.externalId,
      code: competition.code,
      name: competition.name,
    },
    edition: {
      externalId: edition.externalId,
      label: edition.label,
      startsAt: edition.startsAt,
      endsAt: edition.endsAt,
    },
    counts: {
      teams: teams.length,
      rounds: rounds.length,
      matches: matches.length,
    },
    firstTeam: teams[0],
    firstRound: rounds[0],
    firstMatch: matches[0],
  });
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});