FANTAGOL — LIVE RUNTIME INTEGRATION HARNESS v1

File installato:
  scripts/live-runtime-harness.ts

Nessuna modifica a package.json.
Esecuzione tramite npx tsx.

Variabili obbligatorie comuni:
  SUPABASE_URL (oppure NEXT_PUBLIC_SUPABASE_URL)
  SUPABASE_SERVICE_ROLE_KEY
  FOOTBALL_DATA_API_TOKEN (letta dal provider adapter)

Modalità enqueue, variabili obbligatorie:
  FANTAGOL_MATCH_ID          UUID canonico public.matches
  FOOTBALL_DATA_MATCH_ID     ID numerico Football-Data

Variabili enqueue opzionali:
  FANTAGOL_ROUND_ID
  LEAGUE_ROUND_IDS           UUID separati da virgola
  LIVE_RUNTIME_IDEMPOTENCY_KEY
  LIVE_RUNTIME_CORRELATION_ID
  LIVE_RUNTIME_PRIORITY
  LIVE_RUNTIME_MAX_ATTEMPTS

Modalità:
  npx --yes tsx scripts/live-runtime-harness.ts enqueue
  npx --yes tsx scripts/live-runtime-harness.ts once
  npx --yes tsx scripts/live-runtime-harness.ts drain

Per il primo test limitare il worker a poll_match:
  set LIVE_RUNTIME_JOB_TYPES=poll_match

La modalità drain usa LIVE_RUNTIME_MAX_JOBS (default 20).
