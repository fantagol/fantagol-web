FANTAGOL — ODDS SNAPSHOT FEATURE v1

Scope
- H2H / 1X2 only.
- No scoring rule and no 3.80 threshold in the Runtime.
- Stores canonical bookmaker data and a consensus fair decimal price.
- Freezes the latest valid snapshot available at or before lock time.
- Official frozen rows are immutable.
- Resolution Engine will later read the official consensus and apply:
  selected 1X2 fair decimal odds >= 3.80 + correct sign = Surprise Bonus +2.

Files
- supabase/migrations/047_odds_snapshot_foundation.sql
- lib/live-runtime/odds-snapshot.ts
- lib/live-runtime/the-odds-api-snapshot-normalizer.ts
- lib/live-runtime/odds-snapshot-service.ts
- lib/live-runtime/index.ts

Operational order
1. Extract.
2. npm run build.
3. Inspect git diff and SQL pro forma.
4. Apply migration only after explicit verification.
5. Runtime integration test.
6. Commit and push.
